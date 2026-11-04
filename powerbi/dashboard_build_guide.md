# Power BI Dashboard: Build Guide

> Written for **Power BI Desktop 2.159 (October 2026)**. Ribbon menus move between releases, so where a menu
> might differ, the guide uses the routes that have stayed the same: **right-click in the Data pane** and the
> **Format pane** (paintbrush icon in the Visualizations pane).
> All formulas are in `C:\gis\asset\powerbi\measures.dax` (sections A-D). The theme is `C:\gis\asset\powerbi\theme.json`.

## Objective (agreed)

> Show the panel how an automated asset-data pipeline, and the reports it feeds, adds value to the
> Strategic Asset Management team: **faster, consistent checking of as-constructed handovers, a register
> the team can trust, and reliable information for planning.**

- **Audience:** the hiring manager and HR, who are not technical. They judge the *output* and how useful it is, not the code.
- **Role link:** the ad's main duty is "validate and process as-constructed information from subdivisions,
  capital projects and operational works". The demo shows that duty automated.
- **Your position:** you're the data specialist, not the asset engineer. You make the data reliable and useful,
  and the team makes the asset decisions.

**Scope:** 3 report pages plus an optional cover page, built from the existing CSVs (seed-42 sample data).
**Out of scope:** funding ratios (ASR/ARFR), budget what-if, a planning-year table, new data, live database,
multiple submissions.

| Page | Message (one sentence) | Time to build |
|------|------------------------|---------------|
| 0. How it works (optional) | Handover in, checked automatically, clean data in, reports out | 10 min |
| 1. Handover Check | 1,840 checks in seconds; problems caught *before* they enter the register | 45 min |
| 2. Register Health | Data quality is now measured, not assumed | 20 min |
| 3. Planning Insights | Clean data shows where the risk and the renewals are | 25 min |
| Setup, model, template, polish | | 50 min |

**Build page 1 first.** If you run out of time, page 1 alone still makes the pitch.

---

## Step 1. Setup (10 min)

1. **File > Options and settings > Options**. The left panel has two lists, GLOBAL and CURRENT FILE:
   - *CURRENT FILE > Data Load*: untick **Auto date/time**. Under *Relationships*, untick **Autodetect new
     relationships** if you see it. If you don't, delete any auto-created relationships in Step 3 instead.
   - *CURRENT FILE > Regional settings*: locale **English (Australia)**.
   - Leave all other boxes as they are.
2. **Design > Import theme** > `C:\gis\asset\powerbi\theme.json` (City of Mandurah web palette).
3. **File > Save as** `C:\gis\asset\powerbi\asset_dashboard.pbix`. Press **Ctrl+S** often.

## Step 2. Load data (10 min)

Fastest way to load all seven files:
1. **Home > Get data > Text/CSV** > pick the first file > click **Transform Data** (not Load). Power Query opens.
2. Inside Power Query: **Home > New Source > Text/CSV** for each remaining file. Each one is added as a query on the left.
3. Fix the column types (below), then **Home > Close & Apply**.

| File | Table name in Power BI | Role | Used on |
|------|------------------------|------|---------|
| `output\dq_runs.csv` | dq_runs | Run summary | Page 1 |
| `output\submission_outcome.csv` | submission_outcome | Handover rows (one per row) | Page 1 |
| `output\dq_exceptions.csv` | dq_exceptions | Handover issues (fact) | Page 1 |
| `output\rule_evaluation.csv` | rule_evaluation | Rule test results | Page 1 |
| `output\register_completeness.csv` | register_completeness | Completeness by subclass (fact) | Page 2 |
| `output\register_asset.csv` | register_asset | Asset register (fact) | Pages 2-3 |
| `data\ref_asset_class.csv` (note: **data** folder) | dim_asset_type | Shared dimension | All pages (filters) |

For `ref_asset_class`: select `subclass`, `network` and `asset_class`, right-click > **Remove Other Columns**, then
rename the query to `dim_asset_type` (double-click its name in the Queries list).

**Column types.** Click the icon at the left of a column header (ABC / 123 / 1.2) to change its type. If asked,
choose **Replace current**.
- `dq_runs[run_at]`: **Text** (it carries a +11 timezone and isn't needed as a date).
- `register_asset`: `condition`, `risk_score`, `renewal_year` = Whole number; `replacement_value` = Fixed decimal;
  `latitude`, `longitude` = Decimal.
- `dq_exceptions`: `latitude`, `longitude` = Decimal (2 blanks are expected).
- `rule_evaluation[detected]` = True/False.

**Map coordinates.** In **Report view** or **Table view**, click `register_asset[latitude]` in the **Data** pane.
On the **Column tools** tab, set **Data category = Latitude**, then set `longitude` to **Longitude**.
Repeat for `dq_exceptions`. A globe icon appears next to each column.

## Step 3. Model and measures (20 min)

Open `measures.dax` in VS Code or Notepad and copy one block at a time.

**3.1 Calculated columns (section A).** In the **Data** pane, **right-click the table name > New column**,
paste the formula into the formula bar and press **Enter**:
- `dq_exceptions`: `Issue Type`
- `register_asset`: `Planned Year`, `Renewal Type`, `Condition Label`, `Risk Band`, `Risk Band Order`

**Sort the labels in a sensible order** (otherwise Power BI sorts them alphabetically):
- `Risk Band`: select it in the Data pane > **Column tools > Sort by column > `Risk Band Order`**
  (High, Medium, Low, Unknown). Then right-click `Risk Band Order` > **Hide in report view**.
- `Condition Label` needs no helper: its "1 ... 5" prefix already sorts it, with "Unknown" last.

**3.2 Relationships (a simple star schema).** In **Model view** (third icon on the far-left bar), click
**Manage relationships**. Delete any relationship Power BI created by itself, then create these four.
In every case use Cardinality **One to many** (or **Many to one**, depending on which table you pick first) and
Cross-filter direction **Single**:

| # | From (one side) | To (many side) | What it does |
|---|-----------------|----------------|--------------|
| 1 | `dim_asset_type[subclass]` | `register_asset[subclass]` | Network / asset type filter on the register |
| 2 | `dim_asset_type[subclass]` | `register_completeness[subclass]` | Same filter on the completeness heatmap |
| 3 | `dim_asset_type[subclass]` | `submission_outcome[subclass]` | Same filter on the handover results |
| 4 | `submission_outcome[submission_row]` | `dq_exceptions[submission_row]` | Click an outcome to filter the issue list |

- Quicker alternative: in Model view, drag the column from the "one" table onto the matching column in the "many" table.
- For #2, Power BI may suggest **One to one** because each subclass appears once in both tables. Change it to
  **Many to one**, with `register_completeness` as the many side and direction **Single**.
- **Don't** link `dim_asset_type` straight to `dq_exceptions`. It's already filtered through `submission_outcome`,
  and a second path would make Power BI disable one of the relationships.
- `dq_runs` and `rule_evaluation` stay unlinked (run summary and test results).
- Lay out the Model view for a screenshot: dimension at the top, facts below, unlinked tables to the side.

```
                    dim_asset_type
              (subclass, network, asset_class)
           /            |                 \
  register_asset  register_completeness  submission_outcome
                                                |
                                          dq_exceptions
```

**Slicers use the dimension.** For network or asset type, always use `dim_asset_type[network]`, `[asset_class]` or
`[subclass]`, so one slicer filters every visual. Hide the fact-table copies so they can't be picked by mistake:
right-click `register_asset[network]`, `register_asset[asset_class]` and `register_asset[subclass]` > **Hide in report view**.
Leave `subclass` visible in `dq_exceptions` and `submission_outcome`, since tables on page 1 show it.
The planted error "Kerb Inlet Pit XL" isn't a valid subclass, so it appears as **(Blank)** in these slicers.
That's correct, and worth saying in the demo: invalid data is visible, not silently dropped.

**3.3 Measures table.** **Home > Enter data** > change the table name to `_Measures` > **Load**. Then
**right-click `_Measures` in the Data pane > New measure**, paste one block from sections B-D, press **Enter**, and
repeat for each measure. When done, right-click `Column1` > **Delete from model**.

**3.4 Formats.** Click a measure in the Data pane and the **Measure tools** tab appears on the ribbon:
- **Currency** (`$`), 0 decimals: Replacement Cost, Value Added This Handover, High Risk Value, Renewal Backlog,
  Renewals Next 10 Years. On cards, set Display units to **Millions** with 2 decimals ($14.53M)
  (Format pane > Callout value / Value > Display units).
- **Percentage**, 0 decimals: First-Pass Acceptance %, Condition Coverage %, Overall Completeness %.
- **Whole number**, thousands separator on: all counts.

**3.5** Click `register_asset[Planned Year]` in the Data pane > **Column tools** tab > Summarization **Don't summarize**.

**Tip:** a red error under the formula bar usually means a typo in a table or column name, or a column from 3.1
that isn't created yet. Paste the error into the chat if stuck.

## Step 4. Page template (10 min)

Build on page 1, then right-click the page tab at the bottom > **Duplicate page** for the others.
To rename a page, double-click its tab.

- **Title bar**: **Insert > Shapes > Rectangle**. In the Format pane, set Fill `#2261AE` and turn Border off.
  To size it exactly, use Format pane > **General > Properties > Size and position**: Width 1280, Height 60, X 0, Y 0.
  Add a second rectangle for the gold line: fill `#FFCB58`, Height 4, Y 60.
- **Title**: **Insert > Text box**, drag it onto the bar, type the page title (white, Segoe UI Semibold 20) and a
  subtitle line (white, 11): *"Sample data | Handover WAPC-123456 Stage 4 | Checked 3 Nov 2026"*.
  In the text box's Format pane, turn **Background** off so the blue shows through.
- **Page background**: click an **empty part of the canvas** (nothing selected) and the Format pane shows page
  settings. Open **Canvas background**, set Colour `#F8F7F6`, Transparency **0%**.
- **Card look for visuals**: Format pane > **General > Effects**: Background white; **Visual border** on, `#E5E7EB`,
  rounded corners 6.
- **Footer text box** (8 pt, grey): *"Sample data generated for demonstration. Not City of Mandurah data."*

**Shortcuts:** Ctrl+C / Ctrl+V copies a formatted visual, so you can format one card, copy it and swap the field.
Ctrl+click several visuals, then use **Format > Align** to line them up.

---

## Page 0. How it works (optional, 10 min)

Title: **From handover to decision**. Four rounded rectangles left to right (Insert > Shapes), with arrows between them:

| 1. Handover received | 2. Automatic checks | 3. Clean data in | 4. Reports |
|---|---|---|---|
| Consultant's as-constructed data (subdivision, capital project) | 23 rules: missing info, invalid values, duplicates, location | Passed rows added to the register; failed rows go back with a reason | Register health and planning insights, refreshed every run |

Underneath, one line: **"Same rules, every handover, in seconds, with a full record of every decision."**
No technical terms (no SQL, PostGIS or Python) on this page.

## Page 1. Handover Check (45 min), the main page

Title: **Handover Check: Is the consultant's data fit for the register?**

**Row 1, KPI cards (5):**

| Card | Value | Label to show |
|------|-------|---------------|
| `Checks Performed` | 1,840 | "automated checks (80 rows x 23 rules)" |
| `Rows Integrated` | 60 | "added to register" (green value `#4D7C1F`) |
| `Rows Held for Review` | 3 | "held for review" (amber `#A85F00`) |
| `Rows Returned` | 17 | "returned to consultant" (red `#A0252B`) |
| `First-Pass Acceptance %` | 75% | "accepted first time" |

**How to make a card:** click empty canvas > in the Visualizations pane click the **Card** icon > drag the measure
into the field well.
- **Label:** in the field well, double-click the measure name (or right-click > **Rename for this visual**) and type
  the label text.
- **Value colour:** Format pane > **Callout value** (called **Value** in some builds) > Font colour.
- **Fastest route:** format the first card, then copy and paste it four times and swap the measure in each.

**Row 2, three visuals:**
1. **Donut**: Legend `submission_outcome[outcome]`, Values `Submission Rows`.
   Colours (Format pane > Slices): Integrated `#74A333`, Held for review `#FFB020`, Returned to consultant `#A0252B`.
   Detail labels: category + value.
2. **Stacked bar chart, "What went wrong"**: Y `dq_exceptions[Issue Type]`, X `Issues Found`, Legend `severity`
   (Error `#A0252B`, Warning `#FFB020`). Sort descending.
   Expect: Invalid values 7, Location or shape problem 6, Duplicate assets 3, Missing information 2, Inconsistent values 2.
3. **Azure Map, "Where the problems are"**: Latitude `dq_exceptions[latitude]`, Longitude `dq_exceptions[longitude]`,
   Legend `severity`, Tooltips `asset_id`, `rule_name`, `detail`. Map style: Grayscale light.
   Small card underneath: `Issues Not Mappable` (2), labelled "issues with no usable location".
   *Map tip:* use the **Latitude** and **Longitude** wells, not Location. If the map stays blank or shows a warning,
   go to File > Options > GLOBAL > **Security** and tick **Use Azure Map visual**.

**Row 3:**
4. **Table, "Return list for the consultant"**: from `dq_exceptions`: `submission_row`, `asset_id`, `subclass`,
   `Issue Type`, `rule_name`, `detail`, `severity`. Sort by severity, then submission_row.
   Format pane > **Cell elements** > choose `severity` > turn on **Background colour** > **fx** > Rules:
   Error `#A0252B`, Warning `#FFB020`; set Font colour white the same way.
5. **Callout text box** (light yellow fill `#FFF4D6`, or a gold `#FFCB58` border):
   **"Caught: one typo, $2.7M."** Row 17 (road seal) had a unit rate of **$906.75/m²** against an expected
   $25-60. Integrated as-is, it would have overstated the register by about **$2.7M**.
6. **Small card**: `Assurance Label`, which shows "20 of 20 planted test errors caught".

**Interaction check:** click "Returned to consultant" in the donut and the table, bar chart and map should filter.

## Page 2. Register Health (20 min)

Title: **Register Health: Can we trust what's in the register?**

**KPI cards (5):** `Asset Count` (444), `Replacement Cost` ($14.53M), `Assets Added This Handover` (60),
`Value Added This Handover` ($1.66M), `Overall Completeness %` (92%).

**Visuals:**
1. **Bar chart, "What we own"**: Y `dim_asset_type[network]`, X `Replacement Cost`, data labels on.
   Expect Stormwater $6.52M, Transport $6.14M, Lighting $1.86M.
2. **Matrix heatmap, "How complete is the data?"**: Rows `register_completeness[subclass]`;
   Values `material_pct`, `condition_pct`, `criticality_pct`, `dimension_pct` (set each to **Average** or **Don't summarize**).
   Format pane > **Cell elements** > turn on **Background colour** > **fx** > Format style **Rules**:
   < 85 `#F69AA0`, 85 to < 95 `#FFDE88`, >= 95 `#BAD982`. Do this for each of the four values.
   Rename the column headers (double-click in the field well) to Material, Condition, Criticality, Dimensions.
   Blank dimensions for lights and pits are expected (not applicable).
3. **Card + text, "The condition gap"**: `Assets Missing Condition` (50) and `Condition Coverage %` (89%).
   Text: *"50 assets have no condition score. These are the targets for the next inspection round, or for
   automated condition rating from street-level imagery."* (This links to the AI/ML item in the job ad.)
4. **Slicer** (top right): `dim_asset_type[network]`, Dropdown style.

## Page 3. Planning Insights (25 min)

Title: **Planning Insights: What clean data tells us**

**KPI cards (4):** `High Risk Assets` (43), `High Risk Value` ($1.03M), `Renewal Backlog` ($1.67M; `Backlog Assets` = 64),
`Renewals Next 10 Years` ($2.52M).

**Visuals:**
1. **Risk grid (Matrix)**: Rows `register_asset[criticality]`, Columns `register_asset[Condition Label]`, Values `Asset Count`.
   Format pane > **Cell elements** > Background colour > **fx** > Gradient: lowest `#FFFFFF`, highest `#A0252B`.
   Turn off row and column subtotals.
   Subtitle: *"Likelihood (condition 1 = very good ... 5 = very poor) x consequence (criticality)"*.
2. **Azure Map, "Where the risk is"**: Latitude/Longitude from `register_asset`, Legend `Risk Band`
   (High `#A0252B`, Medium `#FFB020`, Low `#74A333`, Unknown `#BEB0A3`), Size `replacement_value`.
   Tooltips `asset_id`, `dim_asset_type[subclass]`, `Condition Label`, `remaining_life_years`.
3. **Stacked column chart, "Renewal outlook, next 10 years"**: X `register_asset[Planned Year]`
   (Format pane > **X-axis** > Type **Categorical**), Y `Replacement Cost`, Legend `Renewal Type`
   (Overdue (backlog) `#A0252B`, Scheduled `#2261AE`).
   Filters pane > this visual > `Planned Year` **is less than or equal to** 2036 (Advanced filtering).
   The first bar (2027) includes the overdue backlog.
4. **Table, "Top priorities"**: `asset_id`, `dim_asset_type[subclass]`, `criticality`, `Condition Label`,
   `remaining_life_years`, `replacement_value`. Filters pane > this visual > `Risk Band` = High.
   Sort `remaining_life_years` ascending. Cell elements > **Data bars** on `replacement_value`.
5. **Slicers**: `dim_asset_type[network]`, `register_asset[Risk Band]`.

**Interaction check:** click a dark cell in the risk grid and the map and table should filter.

---

## Step 5. Polish and back up (15 min)

1. **Navigation**: **Insert > Buttons > Navigator > Page navigator**, placed on the title bar with white text.
   Copy it to the other pages. In Desktop, **Ctrl+click** a button to use it. Buttons don't work in the PDF.
2. **Alt text** on main visuals (Format pane > **General > Alt text**).
3. Rename visual titles to plain English (as given above) and remove anything technical.
4. Clear all slicers, open on page 1 (or page 0), **Save**.
5. **File > Export > Export to PDF**, and keep a copy on your laptop and phone.
   If there's no formal slot, show the PDF or a printed page 1 instead.

## Delivery: three versions to have ready

**If given a slot (5-7 min):** page 0 > 1 > 2 > 3, using the talking points below.

**If informal (about 2 min, laptop or phone):** page 1 only:
> "The job ad's first duty is validating as-constructed data. I automated that. This handover had 80 rows;
> every row went through 23 checks, 1,840 in all, in seconds. 60 went straight into the register,
> 17 went back to the consultant with a reason for each, and this one typo would have added $2.7M of
> phantom value to the register."

**If asked "tell us about a project":** use the same 2-minute version, then offer to show pages 2-3.

## Talking points (5-7 min)

1. **The problem (30 s):** "Consultants hand over as-constructed data for every subdivision and capital project.
   Checking it by hand is slow, inconsistent and hard to audit, and errors flow straight into valuations and renewal plans."
2. **Page 1 (2-3 min):** the 1,840 checks; the outcome split; issue types in plain English; the return list
   *"is the actual attachment that goes back to the consultant"*; the $2.7M typo; 20 of 20 test errors caught:
   *"I tested the rules by planting errors on purpose."*
3. **Page 2 (1 min):** "Data quality is now measured. The team can see completeness by asset type and
   where the gaps are, like 50 assets with no condition score."
4. **Page 3 (1 min):** "I'm not the asset engineer, but clean data lets the engineers see risk and renewals at a glance,
   and it refreshes every time a handover is processed."
5. **Close (30 s), what's next in the role:** run it on every handover automatically; track consultant data quality
   over time; load clean rows straight into TechnologyOne; open the same results in QGIS; use image recognition to fill
   condition gaps.

**Likely questions:**
- *Is this real data?* "No, it's generated sample data shaped like council asset data, with errors planted on purpose
  to test the rules."
- *How long would manual checking take?* Give an honest estimate: "Even at a few minutes a row, that's several hours
  per handover, and the result depends on who checks it."
- *How is risk calculated?* "Condition 1-5 times consequence 1-3 from criticality. 10 or more is high. It's a simple,
  standard approach that the team could tune."
- *How is the data modelled?* (have Model view ready) "A simple star schema: one shared asset-type dimension from the
  City's asset hierarchy, feeding two fact areas, the handover checks and the asset register. One network filter works
  across every page. In a full build I'd add a date dimension for trends across handovers and a consultant dimension
  to track data quality by supplier."
- *What tools?* "Python, PostgreSQL with PostGIS for the spatial checks, and Power BI. The rules are plain SQL, so
  they're easy to review and change."

---

## Colour reference (City of Mandurah web palette)

From the City's website stylesheet; the style guide itself isn't published. The website font (Ginto) is a paid
font, so the theme uses Segoe UI. **Don't use the City logo** (policy POL-CMR 01 requires approval).

| Use | Hex |
|-----|-----|
| City blue: title bar, main series | `#2261AE` |
| Deep blue: headings, card values | `#1B385F` |
| Gold: accent line | `#FFCB58` |
| Off-white: page background | `#F8F7F6` |
| Good / Integrated / Low (fill) | `#74A333` |
| Watch / Held / Medium / Warning (fill) | `#FFB020` |
| Bad / Returned / High / Error (fill) | `#A0252B` |
| Unknown | `#BEB0A3` |
| Text on white: green / amber / red | `#4D7C1F` / `#A85F00` / `#A0252B` |
