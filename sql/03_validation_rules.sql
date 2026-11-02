-- 03_validation_rules.sql : validate an as-constructed submission before integration
-- Usage: psql -v submission_ref="WAPC-123456 Stage 4" -f sql/03_validation_rules.sql
-- Each rule writes one row per failing record into am.dq_exception for this run.

-- Rule catalogue (kept in the database so reports can show names and severities) ----
TRUNCATE am.dq_rule CASCADE;
INSERT INTO am.dq_rule (rule_id, rule_name, category, severity, description) VALUES
 ('R01', 'Missing required attribute',        'Completeness', 'Error',   'Mandatory fields are blank'),
 ('R02', 'Unconvertible value',               'Validity',     'Error',   'A numeric or date field holds text that cannot be converted'),
 ('R03', 'Invalid asset class or subclass',   'Validity',     'Error',   'Subclass is not in the asset hierarchy for the stated class'),
 ('R04', 'Invalid criticality',               'Validity',     'Error',   'Criticality is not Critical, Primary or Secondary'),
 ('R05', 'Invalid status',                    'Validity',     'Error',   'Status is not in the status domain'),
 ('R06', 'Unit rate outside expected range',  'Validity',     'Error',   'Unit rate outside the range set for the subclass'),
 ('R07', 'Useful life outside expected range','Validity',     'Error',   'Useful life outside the range set for the subclass'),
 ('R08', 'Invalid condition score',           'Validity',     'Error',   'Condition is not on the 1-5 scale'),
 ('R09', 'New asset not in very good condition','Consistency','Warning', 'Newly constructed assets are expected to be condition 1'),
 ('R10', 'Dimension outside expected range',  'Validity',     'Error',   'Width or diameter outside the range set for the subclass'),
 ('R11', 'Install date implausible',          'Validity',     'Error',   'Install date is in the future or before 1900'),
 ('R12', 'Duplicate asset ID in submission',  'Uniqueness',   'Error',   'The same asset ID appears more than once in the submission'),
 ('R13', 'Asset ID already in register',      'Uniqueness',   'Error',   'Asset ID is already used by an existing register asset'),
 ('R14', 'Geometry missing or unreadable',    'Spatial',      'Error',   'WKT is blank or cannot be parsed'),
 ('R15', 'Coordinates not in MGA zone 50',    'Spatial',      'Error',   'Coordinates fall outside the valid MGA zone 50 range (often supplied in degrees or another zone)'),
 ('R16', 'Invalid geometry',                  'Spatial',      'Error',   'Geometry fails ST_IsValid'),
 ('R17', 'Self-intersecting line',            'Spatial',      'Error',   'Linear asset crosses itself'),
 ('R18', 'Wrong geometry type',               'Spatial',      'Error',   'Geometry type does not match the subclass (e.g. a pit supplied as a line)'),
 ('R19', 'Outside local government boundary', 'Spatial',      'Error',   'Asset lies outside the local government boundary'),
 ('R20', 'Possible spatial duplicate',        'Spatial',      'Warning', 'An existing asset of the same subclass lies within 1 m; confirm whether this is a renewal or a duplicate'),
 ('R21', 'Replacement value inconsistent',    'Consistency',  'Warning', 'Replacement value differs from quantity x unit rate by more than 1%'),
 ('R22', 'Recorded length differs from geometry','Consistency','Warning', 'Recorded length differs from the measured geometry length by more than 5%'),
 ('R23', 'Quantity inconsistent with geometry','Consistency', 'Warning', 'Quantity differs from the quantity derived from geometry and dimensions by more than 5%');

-- Start a run ------------------------------------------------------------------------
INSERT INTO am.dq_run (submission_ref) VALUES (:'submission_ref') RETURNING run_id \gset

-- Helper view of rows with usable, correctly projected geometry
CREATE OR REPLACE TEMP VIEW s_geom_ok AS
SELECT s.*
FROM am.stg_submission s
WHERE s.geom IS NOT NULL
  AND ST_XMin(s.geom) BETWEEN 100000 AND 900000 AND ST_XMax(s.geom) BETWEEN 100000 AND 900000
  AND ST_YMin(s.geom) BETWEEN 6000000 AND 8000000 AND ST_YMax(s.geom) BETWEEN 6000000 AND 8000000;

-- R01 Missing required attribute
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, submission_row, asset_id, 'R01', 'Missing: ' || missing
FROM (
  SELECT s.*, concat_ws(', ',
      CASE WHEN asset_id IS NULL THEN 'asset_id' END,
      CASE WHEN asset_class IS NULL THEN 'asset_class' END,
      CASE WHEN subclass IS NULL THEN 'subclass' END,
      CASE WHEN criticality IS NULL THEN 'criticality' END,
      CASE WHEN status IS NULL THEN 'status' END,
      CASE WHEN quantity IS NULL THEN 'quantity' END,
      CASE WHEN unit_rate IS NULL THEN 'unit_rate' END,
      CASE WHEN useful_life IS NULL THEN 'useful_life' END,
      CASE WHEN install_date IS NULL AND (type_errors IS NULL OR type_errors NOT LIKE '%install_date%') THEN 'install_date' END,
      CASE WHEN condition IS NULL THEN 'condition' END) AS missing
  FROM am.stg_submission s) m
WHERE missing <> '';

-- R02 Unconvertible value
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, submission_row, asset_id, 'R02', 'Cannot convert: ' || type_errors
FROM am.stg_submission WHERE type_errors IS NOT NULL;

-- R03 Invalid asset class / subclass
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R03',
       format('Class "%s" / subclass "%s" not in hierarchy', s.asset_class, s.subclass)
FROM am.stg_submission s
WHERE s.subclass IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM am.ref_asset_class c
                  WHERE c.subclass = s.subclass
                    AND (s.asset_class IS NULL OR c.asset_class = s.asset_class));

-- R04 / R05 / R08 Domain checks
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R04', format('Criticality "%s"', s.criticality)
FROM am.stg_submission s
WHERE s.criticality IS NOT NULL
  AND s.criticality NOT IN (SELECT value FROM am.ref_domain WHERE domain_name = 'criticality');

INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R05', format('Status "%s"', s.status)
FROM am.stg_submission s
WHERE s.status IS NOT NULL
  AND s.status NOT IN (SELECT value FROM am.ref_domain WHERE domain_name = 'status');

INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R08', format('Condition %s', s.condition)
FROM am.stg_submission s
WHERE s.condition IS NOT NULL
  AND s.condition::text NOT IN (SELECT value FROM am.ref_domain WHERE domain_name = 'condition');

-- R09 New assets should be condition 1
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R09', format('Condition %s for a new asset', s.condition)
FROM am.stg_submission s
WHERE s.condition BETWEEN 2 AND 5;

-- R06 / R07 / R10 Ranges by subclass
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R06',
       format('Unit rate %s outside %s-%s', s.unit_rate, c.unit_rate_min, c.unit_rate_max)
FROM am.stg_submission s JOIN am.ref_asset_class c USING (subclass)
WHERE s.unit_rate NOT BETWEEN c.unit_rate_min AND c.unit_rate_max;

INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R07',
       format('Useful life %s outside %s-%s years', s.useful_life, c.useful_life_min, c.useful_life_max)
FROM am.stg_submission s JOIN am.ref_asset_class c USING (subclass)
WHERE s.useful_life NOT BETWEEN c.useful_life_min AND c.useful_life_max;

INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R10',
       concat_ws('; ',
         CASE WHEN s.width_m NOT BETWEEN c.width_min AND c.width_max
              THEN format('Width %s m outside %s-%s', s.width_m, c.width_min, c.width_max) END,
         CASE WHEN s.diameter_mm NOT BETWEEN c.diameter_mm_min AND c.diameter_mm_max
              THEN format('Diameter %s mm outside %s-%s', s.diameter_mm, c.diameter_mm_min, c.diameter_mm_max) END)
FROM am.stg_submission s JOIN am.ref_asset_class c USING (subclass)
WHERE s.width_m NOT BETWEEN c.width_min AND c.width_max
   OR s.diameter_mm NOT BETWEEN c.diameter_mm_min AND c.diameter_mm_max;

-- R11 Install date plausibility
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, submission_row, asset_id, 'R11', format('Install date %s', install_date)
FROM am.stg_submission
WHERE install_date > current_date OR install_date < date '1900-01-01';

-- R12 Duplicate IDs within the submission
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R12', format('Asset ID used %s times', d.n)
FROM am.stg_submission s
JOIN (SELECT asset_id, count(*) AS n FROM am.stg_submission
      WHERE asset_id IS NOT NULL GROUP BY asset_id HAVING count(*) > 1) d USING (asset_id);

-- R13 ID already in the register
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R13', 'Asset ID exists in register'
FROM am.stg_submission s JOIN am.asset_register r USING (asset_id);

-- R14 Geometry missing or unreadable
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, submission_row, asset_id, 'R14',
       CASE WHEN wkt IS NULL THEN 'No geometry supplied' ELSE 'WKT could not be parsed' END
FROM am.stg_submission WHERE geom IS NULL;

-- R15 Coordinates outside MGA zone 50 range (e.g. supplied in degrees)
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R15',
       format('Extent X %s-%s, Y %s-%s', round(ST_XMin(s.geom)::numeric, 3), round(ST_XMax(s.geom)::numeric, 3),
              round(ST_YMin(s.geom)::numeric, 3), round(ST_YMax(s.geom)::numeric, 3))
FROM am.stg_submission s
WHERE s.geom IS NOT NULL
  AND s.submission_row NOT IN (SELECT submission_row FROM s_geom_ok);

-- R16 Invalid geometry
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, submission_row, asset_id, 'R16', ST_IsValidReason(geom)
FROM s_geom_ok WHERE NOT ST_IsValid(geom);

-- R17 Self-intersecting line
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, submission_row, asset_id, 'R17', 'Line crosses itself'
FROM s_geom_ok
WHERE GeometryType(geom) = 'LINESTRING' AND ST_IsValid(geom) AND NOT ST_IsSimple(geom);

-- R18 Geometry type does not match subclass
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R18',
       format('%s supplied; %s expected for %s', GeometryType(s.geom), c.geometry_type, s.subclass)
FROM s_geom_ok s JOIN am.ref_asset_class c USING (subclass)
WHERE GeometryType(s.geom) <> c.geometry_type;

-- R19 Outside the local government boundary
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, s.submission_row, s.asset_id, 'R19', 'Outside ' || b.lga_name
FROM s_geom_ok s CROSS JOIN am.lga_boundary b
WHERE NOT ST_CoveredBy(s.geom, b.geom);

-- R20 Possible spatial duplicate of an existing asset of the same subclass
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT DISTINCT ON (s.submission_row)
       :run_id, s.submission_row, s.asset_id, 'R20',
       format('Within %s m of register asset %s', round(ST_Distance(s.geom, r.geom)::numeric, 2), r.asset_id)
FROM s_geom_ok s
JOIN am.asset_register r
  ON r.subclass = s.subclass
 AND ST_DWithin(s.geom, r.geom, 1.0)
WHERE ST_IsValid(s.geom)
  AND (GeometryType(s.geom) = 'POINT' OR ST_HausdorffDistance(s.geom, r.geom) < 1.0)
ORDER BY s.submission_row, ST_Distance(s.geom, r.geom);

-- R21 Replacement value = quantity x unit rate (1% tolerance)
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, submission_row, asset_id, 'R21',
       format('Replacement value %s; quantity x rate = %s', replacement_value, round(quantity * unit_rate, 2))
FROM am.stg_submission
WHERE abs(replacement_value - quantity * unit_rate) > 0.01 * quantity * unit_rate;

-- R22 Recorded length vs measured length (valid, simple lines only; 5% tolerance)
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, submission_row, asset_id, 'R22',
       format('Recorded %s m; measured %s m', length_m, round(ST_Length(geom)::numeric, 2))
FROM s_geom_ok
WHERE GeometryType(geom) = 'LINESTRING' AND ST_IsValid(geom) AND ST_IsSimple(geom)
  AND length_m IS NOT NULL
  AND abs(length_m - ST_Length(geom)) > 0.05 * ST_Length(geom);

-- R23 Quantity vs geometry-derived quantity (valid, simple geometry only; 5% tolerance)
INSERT INTO am.dq_exception (run_id, submission_row, asset_id, rule_id, detail)
SELECT :run_id, submission_row, asset_id, 'R23',
       format('Quantity %s %s; derived %s', quantity, unit, round(derived::numeric, 2))
FROM (
  SELECT s.*, CASE c.unit
                WHEN 'm2'   THEN ST_Length(s.geom) * s.width_m
                WHEN 'm'    THEN ST_Length(s.geom)
                WHEN 'each' THEN 1 END AS derived
  FROM s_geom_ok s JOIN am.ref_asset_class c USING (subclass)
  WHERE ST_IsValid(s.geom) AND ST_IsSimple(s.geom) AND GeometryType(s.geom) = c.geometry_type
) q
WHERE derived IS NOT NULL AND quantity IS NOT NULL
  AND abs(quantity - derived) > 0.05 * derived;

-- Summary for this run
SELECT r.rule_id, r.rule_name, r.severity, count(e.exception_id) AS exceptions
FROM am.dq_rule r
LEFT JOIN am.dq_exception e ON e.rule_id = r.rule_id AND e.run_id = :run_id
GROUP BY r.rule_id, r.rule_name, r.severity
ORDER BY r.rule_id;
