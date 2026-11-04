-- 04_integrate_and_report.sql : decide each row's outcome, integrate accepted assets,
-- and build reporting views for Power BI.
-- Run psql from inside the output folder so the CSV exports land there, e.g.
--   cd output
--   psql -f ../sql/04_integrate_and_report.sql

SELECT max(run_id) AS run_id FROM am.dq_run \gset

-- Outcome per submission row:
--   any Error           -> Returned to consultant (request amended data)
--   Warnings only       -> Held for review by an asset officer
--   no exceptions       -> Integrated into the register
CREATE OR REPLACE VIEW am.v_submission_outcome AS
SELECT s.submission_row, s.asset_id, s.subclass, s.project_ref,
       count(e.exception_id) FILTER (WHERE r.severity = 'Error')   AS errors,
       count(e.exception_id) FILTER (WHERE r.severity = 'Warning') AS warnings,
       CASE WHEN count(e.exception_id) FILTER (WHERE r.severity = 'Error') > 0 THEN 'Returned to consultant'
            WHEN count(e.exception_id) > 0 THEN 'Held for review'
            ELSE 'Integrated' END AS outcome
FROM am.stg_submission s
LEFT JOIN am.dq_exception e
       ON e.submission_row = s.submission_row
      AND e.run_id = (SELECT max(run_id) FROM am.dq_run)
LEFT JOIN am.dq_rule r ON r.rule_id = e.rule_id
GROUP BY s.submission_row, s.asset_id, s.subclass, s.project_ref;

-- Integrate clean rows
INSERT INTO am.asset_register (
  asset_id, network, asset_class, subclass, criticality, status, material, length_m, width_m,
  diameter_mm, quantity, unit, unit_rate, replacement_value, useful_life, install_date,
  condition, project_ref, geom, integrated_run_id)
SELECT s.asset_id, s.network, s.asset_class, s.subclass, s.criticality, 'In Service', s.material,
       s.length_m, s.width_m, s.diameter_mm, s.quantity, s.unit, s.unit_rate,
       s.replacement_value, s.useful_life, s.install_date, s.condition, s.project_ref, s.geom, :run_id
FROM am.stg_submission s
JOIN am.v_submission_outcome o USING (submission_row)
WHERE o.outcome = 'Integrated'
ON CONFLICT (asset_id) DO NOTHING;

INSERT INTO am.integration_log (run_id, asset_id, submission_row, action)
SELECT :run_id, asset_id, submission_row, outcome FROM am.v_submission_outcome;

UPDATE am.dq_run d SET
  rows_checked  = o.n,
  rows_accepted = o.accepted,
  rows_review   = o.review,
  rows_returned = o.returned
FROM (SELECT count(*) AS n,
             count(*) FILTER (WHERE outcome = 'Integrated')             AS accepted,
             count(*) FILTER (WHERE outcome = 'Held for review')        AS review,
             count(*) FILTER (WHERE outcome = 'Returned to consultant') AS returned
      FROM am.v_submission_outcome) o
WHERE d.run_id = :run_id;

-- Reporting views ---------------------------------------------------------------------
-- Exceptions with a WGS84 point for Power BI map visuals
CREATE OR REPLACE VIEW am.v_dq_exception_detail AS
SELECT e.run_id, d.submission_ref, e.submission_row, e.asset_id, s.subclass,
       e.rule_id, r.rule_name, r.category, r.severity, e.detail,
       CASE WHEN g.submission_row IS NOT NULL
            THEN ST_Y(ST_Transform(ST_PointOnSurface(g.geom), 4326)) END AS latitude,
       CASE WHEN g.submission_row IS NOT NULL
            THEN ST_X(ST_Transform(ST_PointOnSurface(g.geom), 4326)) END AS longitude
FROM am.dq_exception e
JOIN am.dq_rule r USING (rule_id)
JOIN am.dq_run d USING (run_id)
LEFT JOIN am.stg_submission s USING (submission_row)
LEFT JOIN (SELECT submission_row, geom FROM am.stg_submission
           WHERE geom IS NOT NULL AND ST_IsValid(geom)
             AND ST_XMin(geom) BETWEEN 100000 AND 900000
             AND ST_YMin(geom) BETWEEN 6000000 AND 8000000) g USING (submission_row);

-- Completeness of key attributes across the register, by subclass
CREATE OR REPLACE VIEW am.v_register_completeness AS
SELECT subclass, count(*) AS assets,
       round(100.0 * count(material)    / count(*), 1) AS material_pct,
       round(100.0 * count(condition)   / count(*), 1) AS condition_pct,
       round(100.0 * count(criticality) / count(*), 1) AS criticality_pct,
       round(100.0 * count(CASE WHEN unit <> 'each' THEN coalesce(width_m, diameter_mm) END)
             / NULLIF(count(CASE WHEN unit <> 'each' THEN 1 END), 0), 1) AS dimension_pct
FROM am.asset_register
GROUP BY subclass;

-- Value, condition and remaining life by network and subclass
CREATE OR REPLACE VIEW am.v_register_summary AS
SELECT network, asset_class, subclass, criticality, condition,
       count(*) AS assets,
       sum(quantity) AS quantity, min(unit) AS unit,
       sum(replacement_value) AS replacement_value,
       round(avg(useful_life - extract(year FROM age(current_date, install_date)))::numeric, 1)
         AS avg_remaining_life_years
FROM am.asset_register
GROUP BY network, asset_class, subclass, criticality, condition;

-- Simple age-based renewal forecast: replacement value falling due by year
-- (a starting point only - a full renewal model would also use condition and criticality)
CREATE OR REPLACE VIEW am.v_renewal_forecast AS
SELECT (extract(year FROM install_date) + useful_life)::int AS renewal_year,
       network, subclass, count(*) AS assets, sum(replacement_value) AS renewal_value
FROM am.asset_register
GROUP BY 1, 2, 3;

-- One row per register asset: age, remaining life, straight-line depreciation, a simple
-- risk score and a WGS84 point for map visuals. Feeds the asset consumption ratio,
-- the risk matrix and the prioritised renewal list in Power BI.
CREATE OR REPLACE VIEW am.v_register_asset AS
WITH a AS (
  SELECT r.*,
         (current_date - r.install_date) / 365.25 AS age_exact,
         ST_Transform(ST_PointOnSurface(r.geom), 4326) AS pt
  FROM am.asset_register r
)
SELECT asset_id, network, asset_class, subclass, criticality, condition, status, material,
       quantity, unit, unit_rate, replacement_value, useful_life, install_date,
       (extract(year FROM install_date) + useful_life)::int AS renewal_year,
       floor(age_exact)::int AS age_years,
       round((useful_life - age_exact)::numeric, 1) AS remaining_life_years,
       -- straight-line depreciated replacement cost (fair value); zero once fully consumed
       round(replacement_value * greatest(0, 1 - age_exact / useful_life)::numeric, 2) AS depreciated_value,
       -- annual depreciation expense; fully depreciated assets no longer depreciate
       round(CASE WHEN age_exact < useful_life THEN replacement_value / useful_life ELSE 0 END, 2)
         AS annual_depreciation,
       CASE WHEN age_exact >= useful_life     THEN '1 Backlog (past useful life)'
            WHEN useful_life - age_exact <= 5  THEN '2 Due within 5 years'
            WHEN useful_life - age_exact <= 10 THEN '3 Due in 6-10 years'
            ELSE '4 Due after 10 years' END AS renewal_horizon,
       -- consequence of failure from criticality (3 = Critical .. 1 = Secondary)
       CASE criticality WHEN 'Critical' THEN 3 WHEN 'Primary' THEN 2 WHEN 'Secondary' THEN 1 END
         AS consequence_score,
       -- risk = condition (likelihood, 1-5) x consequence (1-3); NULL when either is unknown
       condition * CASE criticality WHEN 'Critical' THEN 3 WHEN 'Primary' THEN 2 WHEN 'Secondary' THEN 1 END
         AS risk_score,
       CASE WHEN integrated_run_id IS NOT NULL THEN 'Yes' ELSE 'No' END AS from_latest_submission,
       ST_Y(pt) AS latitude,
       ST_X(pt) AS longitude
FROM a;

-- Exports for Power BI -------------------------------------------------------------------
\copy (SELECT * FROM am.v_dq_exception_detail ORDER BY run_id, submission_row, rule_id) TO 'dq_exceptions.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM am.v_submission_outcome ORDER BY submission_row) TO 'submission_outcome.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM am.dq_run ORDER BY run_id) TO 'dq_runs.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM am.v_register_completeness ORDER BY subclass) TO 'register_completeness.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM am.v_register_summary) TO 'register_summary.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM am.v_renewal_forecast ORDER BY renewal_year, network, subclass) TO 'renewal_forecast.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM am.v_register_asset ORDER BY asset_id) TO 'register_asset.csv' WITH (FORMAT csv, HEADER true)

SELECT * FROM am.dq_run WHERE run_id = :run_id;
