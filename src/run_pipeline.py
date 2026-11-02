"""
Run the as-constructed validation pipeline end to end.

  1. (optional) generate sample data
  2. write reference tables from config/data_dictionary.yaml
  3. run the SQL scripts with psql (schema, load, validation rules, integration and reports)
  4. score the rules against the seeded errors (sample data only)

Connection settings come from the standard PostgreSQL environment variables:
  PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
Set PSQL to the full path of psql.exe if it is not on your PATH.

Usage:
  python src/run_pipeline.py --generate --submission-ref "WAPC-123456 Stage 4"
"""
import argparse
import csv
import os
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
DATA, OUTPUT, SQL = ROOT / "data", ROOT / "output", ROOT / "sql"

REF_CLASS_COLS = ["subclass", "network", "asset_class", "geometry", "unit",
                  "unit_rate_min", "unit_rate_max", "useful_life_min", "useful_life_max",
                  "width_min", "width_max", "diameter_mm_min", "diameter_mm_max"]

# Which rule should catch each seeded error (used to score the rules)
EXPECTED_RULE = {
    "E01_MISSING_REQUIRED": "R01", "E02_INVALID_SUBCLASS": "R03", "E03_INVALID_CRITICALITY": "R04",
    "E04_UNIT_RATE_RANGE": "R06", "E05_USEFUL_LIFE_RANGE": "R07", "E06_INVALID_CONDITION": "R08",
    "E07_DUPLICATE_ID_IN_SUBMISSION": "R12", "E08_ID_EXISTS_IN_REGISTER": "R13",
    "E09_INVALID_GEOMETRY": "R16", "E09_SELF_INTERSECTION": "R17", "E10_GEOMETRY_TYPE": "R18",
    "E11_WRONG_CRS": "R15", "E12_OUTSIDE_BOUNDARY": "R19", "E13_SPATIAL_DUPLICATE": "R20",
    "E14_REPLACEMENT_VALUE": "R21", "E15_LENGTH_MISMATCH": "R22", "E16_FUTURE_DATE": "R11",
    "E17_WIDTH_RANGE": "R10",
}


def write_reference_tables():
    dd = yaml.safe_load(open(ROOT / "config" / "data_dictionary.yaml", encoding="utf-8"))
    with open(DATA / "ref_asset_class.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([c if c != "geometry" else "geometry_type" for c in REF_CLASS_COLS])
        for c in dd["asset_classes"]:
            w.writerow([c.get(k, "") for k in REF_CLASS_COLS])
    with open(DATA / "ref_domain.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["domain_name", "value"])
        for v in dd["criticality_values"]:
            w.writerow(["criticality", v])
        for v in dd["status_values"]:
            w.writerow(["status", v])
        for v in dd["condition_scale"]:
            w.writerow(["condition", v])


def psql(script, cwd=ROOT, **variables):
    """Run one SQL script. \\copy paths in the scripts are relative to cwd."""
    # cmd = [os.environ.get("PSQL", "psql"), "-X", "-q", "-v", "ON_ERROR_STOP=1"]
    cmd = [os.environ.get("PSQL", "psql"), "-X", "-q", "-P", "pager=off", "-v", "ON_ERROR_STOP=1"]
    for k, v in variables.items():
        cmd += ["-v", f"{k}={v}"]
    cmd += ["-f", str(SQL / script)]
    print(f"-> {script}")
    subprocess.run(cmd, check=True, cwd=cwd)


def score_rules():
    """Compare exceptions raised with the seeded ground truth."""
    truth = list(csv.DictReader(open(DATA / "seeded_errors.csv", encoding="utf-8")))
    raised = defaultdict(set)
    for e in csv.DictReader(open(OUTPUT / "dq_exceptions.csv", encoding="utf-8")):
        raised[int(e["submission_row"])].add(e["rule_id"])

    rows, caught = [], 0
    for t in truth:
        rule = EXPECTED_RULE[t["error_code"]]
        hit = rule in raised.get(int(t["submission_row"]), set())
        caught += hit
        rows.append({**t, "expected_rule": rule, "detected": hit})
    seeded_rows = {int(t["submission_row"]) for t in truth}
    false_alarms = {r: sorted(v) for r, v in raised.items() if r not in seeded_rows}

    with open(OUTPUT / "rule_evaluation.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"\nSeeded errors detected: {caught}/{len(truth)} ({100 * caught / len(truth):.0f}%)")
    print(f"Rows flagged without a seeded error: {len(false_alarms)} {false_alarms or ''}")
    for r in rows:
        if not r["detected"]:
            print(f"  MISSED row {r['submission_row']}: {r['error_code']} (expected {r['expected_rule']})")
    return caught == len(truth) and not false_alarms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--generate", action="store_true", help="regenerate the sample data first")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--submission-ref", default="WAPC-123456 Stage 4")
    ap.add_argument("--no-score", action="store_true", help="skip scoring (use with real submissions)")
    args = ap.parse_args()

    DATA.mkdir(exist_ok=True)
    OUTPUT.mkdir(exist_ok=True)
    if args.generate:
        sys.path.insert(0, str(ROOT / "src"))
        import generate_sample_data
        generate_sample_data.main(args.seed)

    write_reference_tables()
    psql("01_schema.sql")
    psql("02_load_and_stage.sql", cwd=DATA)
    psql("03_validation_rules.sql", submission_ref=args.submission_ref)
    psql("04_integrate_and_report.sql", cwd=OUTPUT)
    if not args.no_score and (DATA / "seeded_errors.csv").exists():
        ok = score_rules()
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
