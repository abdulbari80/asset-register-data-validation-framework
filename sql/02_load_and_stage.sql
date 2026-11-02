-- 02_load_and_stage.sql : load reference data, boundary, register and the submission
-- Run psql from inside the data folder so the \copy file names resolve, e.g.
--   cd data
--   psql -f ../sql/02_load_and_stage.sql
-- (run_pipeline.py does this for you)

TRUNCATE am.ref_asset_class, am.ref_domain, am.lga_boundary, am.raw_register,
         am.raw_submission, am.stg_submission CASCADE;

\copy am.ref_asset_class FROM 'ref_asset_class.csv' WITH (FORMAT csv, HEADER true)
\copy am.ref_domain FROM 'ref_domain.csv' WITH (FORMAT csv, HEADER true)

CREATE TEMP TABLE tmp_boundary (lga_name text, wkt text);
\copy tmp_boundary FROM 'lga_boundary.csv' WITH (FORMAT csv, HEADER true)
INSERT INTO am.lga_boundary (lga_name, geom)
SELECT lga_name, ST_Multi(ST_GeomFromText(wkt, 7850)) FROM tmp_boundary;

\copy am.raw_register FROM 'asset_register.csv' WITH (FORMAT csv, HEADER true)
\copy am.raw_submission FROM 'ac_submission.csv' WITH (FORMAT csv, HEADER true)

-- Existing register (trusted source in this demo) ---------------------------------
INSERT INTO am.asset_register (
  asset_id, network, asset_class, subclass, criticality, status, material, length_m, width_m,
  diameter_mm, quantity, unit, unit_rate, replacement_value, useful_life, install_date,
  condition, project_ref, geom)
SELECT asset_id, network, asset_class, subclass, criticality, status, NULLIF(material, ''),
       am.try_numeric(length_m), am.try_numeric(width_m), am.try_int(diameter_mm),
       am.try_numeric(quantity), unit, am.try_numeric(unit_rate),
       am.try_numeric(replacement_value), am.try_int(useful_life), am.try_date(install_date),
       am.try_int(condition), NULLIF(project_ref, ''), ST_GeomFromText(wkt, 7850)
FROM am.raw_register;

-- Typed staging for the as-constructed submission -----------------------------------
-- Values that cannot be converted are kept as NULL and listed in type_errors.
INSERT INTO am.stg_submission (
  submission_row, asset_id, network, asset_class, subclass, criticality, status, material,
  length_m, width_m, diameter_mm, quantity, unit, unit_rate, replacement_value, useful_life,
  install_date, condition, project_ref, wkt, geom, type_errors)
SELECT r.submission_row::int,
       NULLIF(trim(r.asset_id), ''), NULLIF(trim(r.network), ''), NULLIF(trim(r.asset_class), ''),
       NULLIF(trim(r.subclass), ''), NULLIF(trim(r.criticality), ''), NULLIF(trim(r.status), ''),
       NULLIF(trim(r.material), ''),
       am.try_numeric(r.length_m), am.try_numeric(r.width_m), am.try_int(r.diameter_mm),
       am.try_numeric(r.quantity), NULLIF(trim(r.unit), ''), am.try_numeric(r.unit_rate),
       am.try_numeric(r.replacement_value), am.try_int(r.useful_life),
       am.try_date(r.install_date), am.try_int(r.condition), NULLIF(trim(r.project_ref), ''),
       NULLIF(trim(r.wkt), ''), am.try_geom(r.wkt, 7850),
       NULLIF(concat_ws(', ',
         CASE WHEN NULLIF(trim(r.length_m), '') IS NOT NULL AND am.try_numeric(r.length_m) IS NULL THEN 'length_m' END,
         CASE WHEN NULLIF(trim(r.width_m), '') IS NOT NULL AND am.try_numeric(r.width_m) IS NULL THEN 'width_m' END,
         CASE WHEN NULLIF(trim(r.quantity), '') IS NOT NULL AND am.try_numeric(r.quantity) IS NULL THEN 'quantity' END,
         CASE WHEN NULLIF(trim(r.unit_rate), '') IS NOT NULL AND am.try_numeric(r.unit_rate) IS NULL THEN 'unit_rate' END,
         CASE WHEN NULLIF(trim(r.useful_life), '') IS NOT NULL AND am.try_int(r.useful_life) IS NULL THEN 'useful_life' END,
         CASE WHEN NULLIF(trim(r.install_date), '') IS NOT NULL AND am.try_date(r.install_date) IS NULL THEN 'install_date' END,
         CASE WHEN NULLIF(trim(r.condition), '') IS NOT NULL AND am.try_int(r.condition) IS NULL THEN 'condition' END
       ), '')
FROM am.raw_submission r;

SELECT (SELECT count(*) FROM am.asset_register) AS register_assets,
       (SELECT count(*) FROM am.stg_submission) AS submission_rows;
