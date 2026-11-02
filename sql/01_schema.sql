-- 01_schema.sql : asset register, staging, reference and data quality tables
-- Coordinate reference system: GDA2020 / MGA zone 50 (EPSG:7850)

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS am;

DROP TABLE IF EXISTS am.integration_log, am.dq_exception, am.dq_run, am.dq_rule,
  am.stg_submission, am.raw_submission, am.raw_register, am.asset_register,
  am.lga_boundary, am.ref_domain, am.ref_asset_class CASCADE;

-- Reference data (loaded from config/data_dictionary.yaml) ----------------------
CREATE TABLE am.ref_asset_class (
  subclass         text PRIMARY KEY,
  network          text NOT NULL,
  asset_class      text NOT NULL,
  geometry_type    text NOT NULL CHECK (geometry_type IN ('POINT', 'LINESTRING', 'POLYGON')),
  unit             text NOT NULL,
  unit_rate_min    numeric, unit_rate_max    numeric,
  useful_life_min  int,     useful_life_max  int,
  width_min        numeric, width_max        numeric,
  diameter_mm_min  int,     diameter_mm_max  int
);

CREATE TABLE am.ref_domain (
  domain_name  text NOT NULL,   -- criticality | status | condition
  value        text NOT NULL,
  PRIMARY KEY (domain_name, value)
);

CREATE TABLE am.lga_boundary (
  lga_name  text PRIMARY KEY,
  geom      geometry(MultiPolygon, 7850) NOT NULL
);

-- Raw imports: everything as text so that bad values can be reported, not rejected
CREATE TABLE am.raw_submission (
  submission_row text, asset_id text, network text, asset_class text, subclass text,
  criticality text, status text, material text, length_m text, width_m text,
  diameter_mm text, quantity text, unit text, unit_rate text, replacement_value text,
  useful_life text, install_date text, condition text, project_ref text, wkt text
);
CREATE TABLE am.raw_register (LIKE am.raw_submission);

-- Asset register --------------------------------------------------------------
CREATE TABLE am.asset_register (
  asset_id           text PRIMARY KEY,
  network            text NOT NULL,
  asset_class        text NOT NULL,
  subclass           text NOT NULL REFERENCES am.ref_asset_class (subclass),
  criticality        text,
  status             text NOT NULL,
  material           text,
  length_m           numeric,
  width_m            numeric,
  diameter_mm        int,
  quantity           numeric NOT NULL,
  unit               text NOT NULL,
  unit_rate          numeric NOT NULL,
  replacement_value  numeric NOT NULL,
  useful_life        int NOT NULL,
  install_date       date NOT NULL,
  condition          int,
  project_ref        text,
  geom               geometry(Geometry, 7850) NOT NULL,
  integrated_at      timestamptz NOT NULL DEFAULT now(),
  integrated_run_id  int
);
CREATE INDEX asset_register_geom_gix ON am.asset_register USING gist (geom);
CREATE INDEX asset_register_subclass_idx ON am.asset_register (subclass);

-- Typed staging table for an as-constructed submission --------------------------
CREATE TABLE am.stg_submission (
  submission_row     int PRIMARY KEY,
  asset_id           text, network text, asset_class text, subclass text,
  criticality        text, status text, material text,
  length_m           numeric, width_m numeric, diameter_mm int, quantity numeric,
  unit               text, unit_rate numeric, replacement_value numeric,
  useful_life        int, install_date date, condition int, project_ref text,
  wkt                text,
  geom               geometry(Geometry, 7850),
  type_errors        text           -- values that could not be converted
);
CREATE INDEX stg_submission_geom_gix ON am.stg_submission USING gist (geom);

-- Data quality rules, runs and exceptions ------------------------------------------
CREATE TABLE am.dq_rule (
  rule_id      text PRIMARY KEY,
  rule_name    text NOT NULL,
  category     text NOT NULL,      -- Completeness | Validity | Uniqueness | Spatial | Consistency
  severity     text NOT NULL CHECK (severity IN ('Error', 'Warning')),
  description  text NOT NULL
);

CREATE TABLE am.dq_run (
  run_id          serial PRIMARY KEY,
  submission_ref  text NOT NULL,
  run_at          timestamptz NOT NULL DEFAULT now(),
  rows_checked    int,
  rows_accepted   int,
  rows_review     int,
  rows_returned   int
);

CREATE TABLE am.dq_exception (
  exception_id    bigserial PRIMARY KEY,
  run_id          int NOT NULL REFERENCES am.dq_run (run_id),
  submission_row  int NOT NULL,
  asset_id        text,
  rule_id         text NOT NULL REFERENCES am.dq_rule (rule_id),
  detail          text
);
CREATE INDEX dq_exception_run_idx ON am.dq_exception (run_id, submission_row);

CREATE TABLE am.integration_log (
  run_id          int REFERENCES am.dq_run (run_id),
  asset_id        text,
  submission_row  int,
  action          text,     -- Integrated | Held for review | Returned to consultant
  logged_at       timestamptz NOT NULL DEFAULT now()
);

-- Safe conversion helpers: return NULL instead of failing the whole load ----------
CREATE OR REPLACE FUNCTION am.try_numeric(v text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN NULLIF(trim(v), '')::numeric;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION am.try_int(v text) RETURNS int
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN NULLIF(trim(v), '')::numeric::int;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION am.try_date(v text) RETURNS date
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN NULLIF(trim(v), '')::date;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION am.try_geom(v text, srid int) RETURNS geometry
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN ST_GeomFromText(NULLIF(trim(v), ''), srid);
EXCEPTION WHEN others THEN RETURN NULL;
END $$;
