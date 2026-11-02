"""
Generate a synthetic asset register and an as-constructed submission for testing.

Outputs (in data/):
  lga_boundary.csv          illustrative local government boundary (WKT, EPSG:7850)
  asset_register.csv        existing register of roads, paths, drainage and street lights
  ac_submission.csv         as-constructed submission for a new subdivision stage,
                            with deliberately seeded data errors
  seeded_errors.csv         ground truth: which submission rows carry which error

All coordinates are GDA2020 / MGA zone 50 (EPSG:7850), around Mandurah, WA.
The boundary is a simplified rectangle for testing only - use the official boundary
(e.g. Landgate or ABS Local Government Areas) for real work.

Only the Python standard library and PyYAML are needed.
Usage:  python src/generate_sample_data.py --seed 42
"""
import argparse
import csv
import math
import random
from datetime import date, timedelta
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"

# Illustrative extent in MGA zone 50 (approximately the Mandurah area)
X0, Y0, X1, Y1 = 372000, 6382000, 392000, 6412000

FIELDS = [
    "submission_row", "asset_id", "network", "asset_class", "subclass", "criticality",
    "status", "material", "length_m", "width_m", "diameter_mm", "quantity", "unit",
    "unit_rate", "replacement_value", "useful_life", "install_date", "condition",
    "project_ref", "wkt",
]


def load_dictionary():
    with open(ROOT / "config" / "data_dictionary.yaml", encoding="utf-8") as f:
        return yaml.safe_load(f)


def spec_for(dd, subclass):
    return next(c for c in dd["asset_classes"] if c["subclass"] == subclass)


def line_wkt(pts):
    return "LINESTRING(" + ", ".join(f"{x:.3f} {y:.3f}" for x, y in pts) + ")"


def point_wkt(x, y):
    return f"POINT({x:.3f} {y:.3f})"


def seg_len(pts):
    return sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def make_asset(rng, dd, subclass, geom_pts, asset_id, install, status, project_ref, condition):
    s = spec_for(dd, subclass)
    rate = round(rng.uniform(s["unit_rate_min"], s["unit_rate_max"]), 2)
    life = rng.randint(s["useful_life_min"], s["useful_life_max"])
    rec = dict.fromkeys(FIELDS, "")
    rec.update(
        asset_id=asset_id, network=s["network"], asset_class=s["asset_class"], subclass=subclass,
        criticality=rng.choice(dd["criticality_values"]), status=status, unit=s["unit"],
        unit_rate=rate, useful_life=life, install_date=install.isoformat(),
        condition=condition, project_ref=project_ref,
    )
    if s["geometry"] == "LINESTRING":
        length = round(seg_len(geom_pts), 2)
        rec["length_m"] = length
        rec["wkt"] = line_wkt(geom_pts)
        if subclass == "Stormwater Pipe":
            rec["material"] = "RCP"
            rec["diameter_mm"] = rng.choice([225, 300, 375, 450, 600])
            qty = length
        else:
            rec["material"] = "Asphalt" if subclass == "Local Road Seal" else "Concrete"
            width = round(rng.uniform(s["width_min"], s["width_max"]), 1)
            rec["width_m"] = width
            qty = round(length * width, 2)
    else:
        x, y = geom_pts[0]
        rec["wkt"] = point_wkt(x, y)
        rec["material"] = "Concrete" if subclass == "Side Entry Pit" else "Steel"
        qty = 1
    rec["quantity"] = qty
    rec["replacement_value"] = round(qty * rate, 2)
    return rec


def build_street_block(rng, dd, ox, oy, prefix, start_no, install, status, project_ref, condition,
                       n_streets=6, street_len=400, spacing=80):
    """A simple grid of streets with paths, pipes, pits and lights."""
    assets, no = [], start_no

    def nid():
        nonlocal no
        no += 1
        return f"{prefix}{no:06d}"

    for i in range(n_streets):
        y = oy + i * spacing
        road = [(ox, y), (ox + street_len / 2, y + rng.uniform(-3, 3)), (ox + street_len, y)]
        assets.append(make_asset(rng, dd, "Local Road Seal", road, nid(), install, status, project_ref, condition))
        path = [(px, py + 6.0) for px, py in road]
        assets.append(make_asset(rng, dd, "Concrete Footpath", path, nid(), install, status, project_ref, condition))
        pipe = [(px, py - 3.0) for px, py in road]
        assets.append(make_asset(rng, dd, "Stormwater Pipe", pipe, nid(), install, status, project_ref, condition))
        for px in (ox, ox + street_len):
            assets.append(make_asset(rng, dd, "Side Entry Pit", [(px, y - 4.0)], nid(), install, status, project_ref, condition))
        for k in range(0, int(street_len) + 1, 40):
            assets.append(make_asset(rng, dd, "LED Street Light", [(ox + k, y + 9.0)], nid(), install, status, project_ref, condition))
    return assets, no


def seed_errors(rng, dd, sub, register):
    """Introduce one known error into selected submission rows. Returns ground truth rows."""
    truth = []
    reg_ids = [r["asset_id"] for r in register]
    reg_lights = [r for r in register if r["subclass"] == "LED Street Light"]
    lines = [r for r in sub if r["wkt"].startswith("LINESTRING")]
    points = [r for r in sub if r["wkt"].startswith("POINT")]
    used = set()

    def pick(pool):
        cands = [r for r in pool if r["submission_row"] not in used]
        r = rng.choice(cands)
        used.add(r["submission_row"])
        return r

    def mark(r, code):
        truth.append({"submission_row": r["submission_row"], "asset_id": r["asset_id"], "error_code": code})

    # Errors that need a specific asset type are seeded first
    r = pick([l for l in lines if l["subclass"] == "Concrete Footpath"]); r["width_m"] = 9.5
    r["quantity"] = round(float(r["length_m"]) * 9.5, 2)
    r["replacement_value"] = round(r["quantity"] * float(r["unit_rate"]), 2); mark(r, "E17_WIDTH_RANGE")
    r = pick([p for p in points if p["subclass"] == "LED Street Light"])
    lx, ly = map(float, rng.choice(reg_lights)["wkt"][6:-1].split())
    r["wkt"] = point_wkt(lx + 0.4, ly - 0.3); mark(r, "E13_SPATIAL_DUPLICATE")
    r = pick(sub); r["subclass"] = ""; mark(r, "E01_MISSING_REQUIRED")
    r = pick(sub); r["install_date"] = ""; mark(r, "E01_MISSING_REQUIRED")
    r = pick(sub); r["subclass"] = "Kerb Inlet Pit XL"; mark(r, "E02_INVALID_SUBCLASS")
    r = pick(sub); r["criticality"] = "High"; mark(r, "E03_INVALID_CRITICALITY")
    r = pick(sub); r["unit_rate"] = round(float(r["unit_rate"]) * 25, 2)
    r["replacement_value"] = round(float(r["quantity"]) * r["unit_rate"], 2); mark(r, "E04_UNIT_RATE_RANGE")
    r = pick(sub); r["useful_life"] = 250; mark(r, "E05_USEFUL_LIFE_RANGE")
    r = pick(sub); r["condition"] = 7; mark(r, "E06_INVALID_CONDITION")
    a = pick(sub); b = pick(sub); b["asset_id"] = a["asset_id"]
    mark(a, "E07_DUPLICATE_ID_IN_SUBMISSION"); mark(b, "E07_DUPLICATE_ID_IN_SUBMISSION")
    r = pick(sub); r["asset_id"] = rng.choice(reg_ids); mark(r, "E08_ID_EXISTS_IN_REGISTER")
    r = pick(lines); x, y = map(float, r["wkt"][11:-1].split(",")[0].split())
    r["wkt"] = line_wkt([(x, y), (x, y)]); mark(r, "E09_INVALID_GEOMETRY")
    r = pick(lines); x, y = map(float, r["wkt"][11:-1].split(",")[0].split())
    r["wkt"] = line_wkt([(x, y), (x + 30, y), (x + 30, y + 10), (x + 15, y - 10)]); mark(r, "E09_SELF_INTERSECTION")
    r = pick(points); x, y = map(float, r["wkt"][6:-1].split())
    r["wkt"] = line_wkt([(x, y), (x + 1.5, y)]); mark(r, "E10_GEOMETRY_TYPE")
    r = pick(points); r["wkt"] = point_wkt(115.7231, -32.5294); mark(r, "E11_WRONG_CRS")
    r = pick(points); r["wkt"] = point_wkt(X1 + 2500, Y0 + 5000); mark(r, "E12_OUTSIDE_BOUNDARY")
    r = pick(sub); r["replacement_value"] = round(float(r["replacement_value"]) * 1.3, 2); mark(r, "E14_REPLACEMENT_VALUE")
    r = pick(lines); r["length_m"] = round(float(r["length_m"]) * 1.4, 2); mark(r, "E15_LENGTH_MISMATCH")
    r = pick(sub); r["install_date"] = (date.today() + timedelta(days=200)).isoformat(); mark(r, "E16_FUTURE_DATE")
    return truth


def write_csv(path, rows, fields):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)


def main(seed=42):
    rng = random.Random(seed)
    dd = load_dictionary()
    DATA.mkdir(exist_ok=True)

    # Existing register: several established blocks
    register, no = [], 0
    for bx, by in [(374000, 6385000), (378000, 6392000), (383000, 6398000), (386000, 6404000)]:
        yrs_ago = rng.randint(5, 35)
        block, no = build_street_block(rng, dd, bx, by, "CM", no, date(2025 - yrs_ago, 6, 30),
                                       "In Service", "", condition=rng.choice([2, 3, 4]))
        register += block
    for r in register:
        r["condition"] = rng.choice([1, 2, 2, 3, 3, 4, 5])
        # Realistic gaps in a legacy register (reported by the completeness view)
        if rng.random() < 0.06:
            r["material"] = ""
        if rng.random() < 0.12:
            r["condition"] = ""
        if rng.random() < 0.04:
            r["criticality"] = ""
        if r["width_m"] != "" and rng.random() < 0.08:
            r["width_m"] = ""

    # As-constructed submission: a new subdivision stage next to an existing block
    sub, _ = build_street_block(rng, dd, 386000, 6404000 + 480, "NEW", 0, date(2026, 9, 15),
                                "Constructed", "WAPC-123456 Stage 4", condition=1, n_streets=5)
    for i, r in enumerate(sub, 1):
        r["submission_row"] = i
    truth = seed_errors(rng, dd, sub, register)

    boundary = f"POLYGON(({X0} {Y0}, {X1} {Y0}, {X1} {Y1}, {X0} {Y1}, {X0} {Y0}))"
    write_csv(DATA / "lga_boundary.csv", [{"lga_name": "Illustrative LGA boundary", "wkt": boundary}], ["lga_name", "wkt"])
    write_csv(DATA / "asset_register.csv", register, FIELDS)
    write_csv(DATA / "ac_submission.csv", sub, FIELDS)
    write_csv(DATA / "seeded_errors.csv", truth, ["submission_row", "asset_id", "error_code"])
    print(f"register: {len(register)} assets | submission: {len(sub)} assets | seeded errors: {len(truth)}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=42)
    main(ap.parse_args().seed)
