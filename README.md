# Media Analytics Pipeline — Pure GCP (BigQuery + Cloud Storage)

An end-to-end campaign analytics pipeline built entirely on native Google Cloud
services. **No dbt, no DuckDB, no external frameworks** — just Cloud Storage,
BigQuery SQL, and `bq`/`gcloud`. You can stand the whole thing up in a few
minutes and show a live, queryable model plus a dashboard.

---

## 1. Architecture

```
  raw files (CSV / NDJSON)
        │  gcloud storage cp
        ▼
  ┌─────────────────┐     LOAD DATA (SQL)      ┌──────────────────────────────┐
  │ Cloud Storage   │ ───────────────────────► │ BigQuery: raw dataset        │
  │ (landing bucket)│                          │  meta / google / visits /    │
  └─────────────────┘                          │  metadata (+ fx, dma seeds)  │
                                               └──────────────┬───────────────┘
                                CREATE VIEW (SQL)             │
                                               ┌──────────────▼───────────────┐
                                               │ BigQuery: staging (views)    │
                                               │  cleaning + all DQ fixes     │
                                               └──────────────┬───────────────┘
                             CREATE TABLE (SQL) partitioned/clustered
                                               ┌──────────────▼───────────────┐
                                               │ BigQuery: marts (tables)     │
                                               │  dim_campaign, fct_*, OBT    │
                                               │  + q1..q4 answer views       │
                                               │  + ASSERT data-quality tests │
                                               └──────────────┬───────────────┘
                                                              ▼
                                               Looker Studio dashboard  ← "show them"

  Scheduling (prod): Cloud Scheduler ─► BigQuery scheduled query  (CALL sp_run_pipeline)
                     …or Cloud Scheduler ─► Cloud Workflows ─► BigQuery (load→build→test)
```

### GCP services used (and why)

| Service | Role | Why (vs the alternative) |
|---|---|---|
| **Cloud Storage** | Landing zone for raw extracts | Standard ingestion pattern; decouples arrival from load. |
| **BigQuery** | Warehouse **and** transformation engine | SQL-only transforms via `CREATE VIEW/TABLE`; no separate compute. |
| **BigQuery `LOAD DATA`** | GCS → BigQuery ingestion | Native SQL load — removes the need for a Python loader. |
| **BigQuery `ASSERT`** | Data-quality tests | The no-dbt equivalent of dbt tests; fails the job on bad data. |
| **BigQuery scheduled query / Cloud Workflows** | Orchestration | Serverless and native; no Composer/Airflow to run. |
| **Looker Studio** | Dashboard | Free, native BigQuery connector — the thing you screen-share. |

---

## 2. Deploy in ~5 minutes (Google Cloud Shell)

Cloud Shell has `gcloud`, `bq`, and auth already — nothing to install.

```bash
git clone <your-repo-url> media-analytics-gcp && cd media-analytics-gcp

export GCP_PROJECT_ID="your-project-id"
export RAW_BUCKET="gs://${GCP_PROJECT_ID}-media-landing"

chmod +x deploy.sh
./deploy.sh
```

`deploy.sh` enables APIs, creates the bucket, uploads the four files, then runs
`sql/01` → `sql/06` in order and prints the four answers. Total data is ~3 MB,
so this runs inside the BigQuery free tier (**≈ $0**).

---

## 3. What each step does (walk-through)

| File | Creates | What it handles |
|---|---|---|
| `sql/01_setup.sql` | datasets `raw`/`staging`/`marts`; seed tables `raw.fx_rates`, `raw.dma_region_map` | The FX conversion factors and the DMA→region crosswalk (a documented assumption). |
| `sql/02_load_raw.sql` | `raw.*` tables | `LOAD DATA OVERWRITE` from GCS with explicit CSV schemas; NDJSON loaded nested then flattened. `OVERWRITE` = idempotent re-runs. |
| `sql/03_staging.sql` | `staging.stg_*` **views** | All data-quality fixes (below). Views are free and always fresh. |
| `sql/04_marts.sql` | `marts.*` **tables** | Star schema, partitioned by `date_day`, clustered by campaign — fast for dashboards. |
| `sql/05_analytics.sql` | `marts.q1..q4` **views** | The four business questions as queryable objects. |
| `sql/06_tests.sql` | (runs `ASSERT`s) | Fails if grain/uniqueness/referential-integrity is violated. |
| `sql/99_production_procedures.sql` | `marts.sp_*` procedures | Wraps load+build so a scheduler can run the whole pipeline with one `CALL`. |

---

## 4. Data model & grain

A **star schema** with a denormalized one-big-table on top.

| Table | Grain (one row per…) | Notes |
|---|---|---|
| `marts.dim_campaign` | `campaign_id` | Brand, product_line, region, dates, budget, canonical name. |
| `marts.fct_ad_performance_daily` | `date × platform × campaign_id` | Additive measures only; MD5 surrogate key; partitioned/clustered. |
| `marts.fct_store_visits_daily` | `date × dma_code` | Enriched with region. |
| `marts.mart_campaign_performance` | `date × platform × campaign_id` | OBT = fact + campaign attributes + pre-computed `month_start`/`week_start`. Dashboard hits this. |

**Why additive-only measures:** CPA/CTR/ROAS are ratios and are *non-additive* —
you can't average a CPA across rows. We store `sum(spend)` and `sum(conversions)`
and divide at query time. Every answer view uses
`sum(numerator)/nullif(sum(denominator),0)`.

---

## 5. Data-quality decisions (the messy bits — be ready to defend these)

| # | Issue | Decision | Where |
|---|---|---|---|
| 1 | Meta `spend_usd` sometimes in CAD/GBP, `currency` sometimes null | Convert to USD via `raw.fx_rates`; null currency → USD | `stg_meta_ads` |
| 2 | Google `cost_micros` in micros | ÷ 1,000,000 | `stg_google_ads` |
| 3 | Google export bug duplicates (campaign, date) rows | Keep one row (max impressions); spend/conversions are identical within dup groups so no double-count | `stg_google_ads` |
| 4 | Campaign renamed mid-flight (1090) | Key on `campaign_id`; canonical = most recent name across both platforms | `dim_campaign` |
| 5 | Meta grain finer than Google | Roll Meta up to campaign/day, then union | `fct_ad_performance_daily` |
| 6 | Store visits per-DMA, no crosswalk | Relate at **region × week** via `dma_region_map`; national campaigns fan to both regions — no fabricated per-campaign join | `q3` |
| 7 | Missing visit days | Left absent (not zero-filled); can't tell "zero" from "unmeasured" | `q3` |
| 8 | Budget missing for 9/24 campaigns | Three explicit statuses: `OVER_BUDGET` / `WITHIN_BUDGET` / `NO_BUDGET_ON_RECORD` | `q4` |
| 9 | Mixed attribution windows (7/14/28) | Summed as-reported (no double-count; one window per row); flagged | `q3` |
| 10 | Timezones differ (Meta PST, Google UTC) | Joined on provided calendar `date`; raw timestamps retained | staging |

---

## 6. The four answers (verified against the data)

- **Q1 — Blended CPA by brand & month:** stable at **~$44–47 / conversion**.
  Note only one brand (`HomeBase`) exists, so this is really CPA-by-month — the
  more useful cut is `product_line`.
- **Q2 — Top 10 WoW spend growth (last 4 complete weeks):** top mover is
  campaign **1033 (Seasonal), +67%** into the week of Jun 8. Trailing partial
  week excluded.
- **Q3 — Spend vs store visits (region × week):** weak-positive correlation
  (East ≈ 0.29, West ≈ 0.32); spend-per-visit rises over time (diminishing
  returns). Descriptive, not causal — by design.
- **Q4 — Budget overspend:** **13 over budget, 2 within, 9 not evaluable.**
  ⚠️ Overspends are very large (200–1000%+) — flag to verify whether `budget_usd`
  is per-channel/monthly rather than lifetime, instead of silently "fixing" it.

---

## 7. Show it — three presentation surfaces

**A. GitHub repo** (baseline): `git init && git add . && git commit && git push`.

**B. Live BigQuery access for the reviewer** (impressive, low effort):
```bash
bq add-iam-policy-binding --member="user:reviewer@example.com" \
  --role="roles/bigquery.dataViewer" "${GCP_PROJECT_ID}:marts"
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="user:reviewer@example.com" --role="roles/bigquery.jobUser"
```
They can now query `marts.q1_blended_cpa_by_brand_month`, etc. themselves.

**C. Looker Studio dashboard** (best for a media role — this is the "working model"):
1. lookerstudio.google.com → Create → Data source → **BigQuery** → your project →
   `marts` → `mart_campaign_performance`.
2. Build tiles that mirror the questions:
   - **Blended CPA by month** — time series, metric `SUM(spend_usd)/SUM(conversions)`.
   - **Spend by campaign** — bar chart, with a `platform` filter control.
   - **Budget status** — table from `marts.q4_budget_overspend_flags`, colored by `budget_status`.
   - **Spend vs visits** — from `marts.q3_spend_vs_store_visits`.
3. Share the report link (view access) in your submission email.

---

## 8. Productionizing (what they'll ask about)

- **Scheduling — option 1 (simplest):** install procedures then a scheduled query:
  ```bash
  sed "s|__RAW_BUCKET__|${RAW_BUCKET}|g" sql/99_production_procedures.sql \
    | bq query --use_legacy_sql=false --project_id="$GCP_PROJECT_ID"
  ./orchestration/scheduled_query.sh          # daily CALL marts.sp_run_pipeline()
  ```
- **Scheduling — option 2 (observable + test-gated):** Cloud Workflows +
  Scheduler — `./orchestration/deploy_workflow.sh`. The workflow runs
  load → build → **ASSERT tests**; a test failure fails the run so bad data never
  goes live.
- **Incremental:** raw ad tables are date-partitioned. In production, load only
  the newly-landed date partitions (`WRITE_APPEND` on the day's file) with a
  short lookback to absorb platform restatements; the fact grain
  `(date, platform, campaign_id)` is idempotent, so re-processing a day overwrites
  cleanly instead of duplicating.
- **Monitoring:** BigQuery `INFORMATION_SCHEMA.JOBS` for run history/cost;
  scheduled-query run history; a row-count anomaly check as an extra ASSERT.
- **Alerting:** Cloud Monitoring alert on workflow/scheduled-query failure →
  email/PagerDuty.

---

## 9. Repo layout

```
media-analytics-gcp/
├── README.md
├── deploy.sh                       # one-command end-to-end deploy
├── data/                           # the four raw extracts
├── sql/
│   ├── 01_setup.sql                # datasets + seed tables
│   ├── 02_load_raw.sql             # LOAD DATA from GCS
│   ├── 03_staging.sql              # cleaning views (DQ fixes)
│   ├── 04_marts.sql                # star schema tables
│   ├── 05_analytics.sql            # q1..q4 answer views
│   ├── 06_tests.sql                # ASSERT data-quality checks
│   └── 99_production_procedures.sql# sp_load_raw / sp_build_marts / sp_run_pipeline
└── orchestration/
    ├── scheduled_query.sh          # daily scheduled query (simple)
    ├── workflow.yaml               # Cloud Workflows (test-gated)
    └── deploy_workflow.sh          # deploy workflow + scheduler
```

---

## 10. Interview talking points

- **Why SQL-only on BigQuery:** the brief said don't over-engineer. A clean
  BigQuery-native pipeline nails the fundamentals without standing up extra
  infrastructure — and it's trivially schedulable with a scheduled query.
- **Grain discipline:** I can state the grain of every table and why the fact is
  additive-only.
- **Deliberate messy-bit calls:** each of the ten decisions in §5 was a choice
  with a stated reason (currency null→USD, dedup keeps one row, missing budget is
  "not evaluated", no fabricated DMA join).
- **Honest flags:** the Q4 overspend magnitudes and the single-brand caveat are
  things I surface rather than hide — that's the judgment they're scoring.
```
