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

## Requirements

- PostgreSQL 14+ with PostGIS 3. On Windows, PostGIS is installed separately through
  **Application Stack Builder** (installed with PostgreSQL): choose your server, then
  *Spatial Extensions > PostGIS 3.x*.
- `psql` on your PATH, or the `PSQL` environment variable set to the full path of `psql`
  (for example `C:\Program Files\PostgreSQL\18\bin\psql.exe`).
- Python 3.10+ with PyYAML.

## Run it

**1. Install the Python dependencies**

```bash
pip install -r requirements.txt
```

**2. Set the connection details** (use the block for your shell)

PowerShell (Windows, including the VS Code terminal):

```powershell
$env:PGHOST = "localhost"
$env:PGPORT = "5432"
$env:PGUSER = "postgres"
$env:PGPASSWORD = "your-password"
$env:PGDATABASE = "assets"
# only if psql is not on your PATH:
$env:PSQL = "C:\Program Files\PostgreSQL\18\bin\psql.exe"
```

Command Prompt (Windows):

```bat
set PGHOST=localhost
set PGPORT=5432
set PGUSER=postgres
set PGPASSWORD=your-password
set PGDATABASE=assets
```

macOS / Linux:

```bash
export PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=your-password PGDATABASE=assets
```

Keep your password in the terminal session only; do not commit it to the repository.

**3. Create the database** (first run only)

```bash
psql -d postgres -c "CREATE DATABASE assets;"
```

The PostGIS extension is enabled automatically by `sql/01_schema.sql`.

**4. Run the pipeline**

```bash
python src/run_pipeline.py --generate
```

This generates the sample data, runs the four SQL scripts in order with `psql`, and ends
with the score:

```
Seeded errors detected: 20/20 (100%)
Rows flagged without a seeded error: 0
```

The PostGIS notices printed during validation (for example *Too few points in geometry
component*) are expected: they come from the deliberately invalid test geometry.

### Options

| Option | Default | Purpose |
|---|---|---|
| `--generate` | off | Regenerate the sample data before running |
| `--seed` | `42` | Random seed for the sample data |
| `--submission-ref` | `WAPC-123456 Stage 4` | Reference recorded against the submission |
| `--no-score` | off | Skip scoring (use with real submissions, which have no seeded errors) |

## Outputs

- `output/`: CSV files for Power BI, plus `rule_evaluation.csv` (each seeded error, the
  rule expected to catch it and whether it did).
- `data/`: generated sample data and reference tables.
- The `am` schema in the database. Open the tables in QGIS via
  *Layer > Add Layer > Add PostGIS Layers*.

`data/` and `output/` are created automatically on each run and are not committed to the
repository.

## Project structure

```
config/data_dictionary.yaml      asset hierarchy, domains, unit-rate and useful-life ranges
src/generate_sample_data.py      synthetic register + as-constructed submission + seeded errors
src/run_pipeline.py              runs the SQL steps with psql and scores the results
sql/01_schema.sql                tables, indexes and safe-conversion functions
sql/02_load_and_stage.sql        loads reference data, boundary, register and submission
sql/03_validation_rules.sql      23 validation rules writing to am.dq_exception
sql/04_integrate_and_report.sql  outcomes, integration, reporting views and CSV exports
dags/asset_dq_dag.py             optional Apache Airflow schedule
```

## Notes and limitations

- All data is synthetic, and the boundary is a simplified rectangle. Unit rates and useful
  lives are illustrative, not any council's adopted values.
- The rules are modelled on the kind of checks A-SPEC validation performs; they are not
  an implementation of the A-SPEC specification itself.
- The renewal forecast is age-based only. A full renewal model would also weight
  condition and criticality.
- The Airflow DAG is optional and not needed to run the pipeline. Airflow does not run
  natively on Windows (use WSL or Docker).
