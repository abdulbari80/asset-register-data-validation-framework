# Asset Register Data Quality and As-Constructed Validation Framework

Validates as-constructed asset data (roads, paths, drainage and street lights) before it is
integrated into a local government asset register, then reports data quality and register
health in Power BI.

Many Western Australian councils receive as-constructed data from developers and consultants
under the A-SPEC specifications (R-Spec for roads, D-Spec for drainage, O-Spec for open space)
and validate it before acceptance. This project reproduces that workflow on synthetic data
in GDA2020 / MGA zone 50 (EPSG:7850), the projection used around Mandurah.

## What it does

1. **Generates test data**: an existing register and a new subdivision submission with
   20 deliberately seeded errors (missing attributes, invalid domains, out-of-range unit
   rates and useful lives, duplicate IDs, invalid or self-intersecting geometry, wrong
   geometry type, coordinates in degrees, assets outside the boundary, spatial duplicates,
   inconsistent replacement values and lengths, future install dates).
2. **Loads and stages** the data in PostgreSQL/PostGIS with safe type conversion, so bad
   values are reported rather than breaking the load.
3. **Applies 23 validation rules** (completeness, validity, uniqueness, spatial and
   consistency) driven by a data dictionary (`config/data_dictionary.yaml`).
4. **Decides each asset's outcome**: *Integrated* (no issues), *Held for review*
   (warnings only) or *Returned to consultant* (errors), and logs every decision.
5. **Publishes reporting views and CSV exports** for Power BI: exceptions with map
   coordinates, outcomes, register completeness, value and remaining life, and a simple
   age-based renewal forecast.
6. **Scores itself**: compares the exceptions raised with the seeded errors.

Result on the sample data: **20 of 20 seeded errors detected, with no false alarms**
(also checked with several random seeds).

## Run it

Requirements: PostgreSQL 14+ with PostGIS 3, `psql` on your PATH, Python 3.10+ with PyYAML.

```bash
pip install -r requirements.txt
# connection settings
set PGHOST=localhost & set PGDATABASE=assets & set PGUSER=postgres & set PGPASSWORD=...   (Windows)
export PGHOST=localhost PGDATABASE=assets PGUSER=postgres PGPASSWORD=...                  (macOS/Linux)

python src/run_pipeline.py --generate
```

Outputs land in `output/` (CSV files for Power BI) and in the `am` schema in the database
(open the tables in QGIS via *Layer > Add Layer > Add PostGIS Layers*).

## Project structure

```
config/data_dictionary.yaml   asset hierarchy, domains, unit-rate and useful-life ranges
src/generate_sample_data.py   synthetic register + as-constructed submission + seeded errors
src/run_pipeline.py           runs the SQL steps with psql and scores the results
sql/01_schema.sql             tables, indexes and safe-conversion functions
sql/02_load_and_stage.sql     loads reference data, boundary, register and submission
sql/03_validation_rules.sql   23 validation rules writing to am.dq_exception
sql/04_integrate_and_report.sql  outcomes, integration, reporting views and CSV exports
dags/asset_dq_dag.py          optional Apache Airflow schedule
```

## Notes and limitations

- All data is synthetic, and the boundary is a simplified rectangle. Unit rates and useful
  lives are illustrative, not any council's adopted values.
- The rules are modelled on the kind of checks A-SPEC validation performs; they are not
  an implementation of the A-SPEC specification itself.
- The renewal forecast is age-based only. A full renewal model would also weight
  condition and criticality.
