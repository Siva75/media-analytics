#!/usr/bin/env bash
# =====================================================================
# deploy.sh — stand up the whole pipeline on GCP, end to end.
# Prereqs: gcloud + bq installed and authenticated (both are pre-installed
# in Google Cloud Shell, where this is easiest to run).
#
# Usage:
#   export GCP_PROJECT_ID="your-project"
#   export RAW_BUCKET="gs://your-project-media-landing"   # will be created
#   ./deploy.sh
# =====================================================================
set -euo pipefail

: "${GCP_PROJECT_ID:?set GCP_PROJECT_ID}"
: "${RAW_BUCKET:?set RAW_BUCKET (e.g. gs://your-project-media-landing)}"
BQ_LOCATION="${BQ_LOCATION:-US}"
Q="bq query --use_legacy_sql=false --project_id=${GCP_PROJECT_ID}"

echo "==> [1/7] Configure project + enable APIs"
gcloud config set project "$GCP_PROJECT_ID" >/dev/null
gcloud services enable bigquery.googleapis.com storage.googleapis.com >/dev/null

echo "==> [2/7] Create landing bucket + upload raw files"
gcloud storage buckets create "$RAW_BUCKET" --location="$BQ_LOCATION" 2>/dev/null || true
gcloud storage cp data/meta_ads_daily.csv data/google_ads_daily.json \
                   data/store_visits.csv data/campaign_metadata.csv "$RAW_BUCKET/"

echo "==> [3/7] Create datasets + seed tables (01_setup.sql)"
$Q < sql/01_setup.sql

echo "==> [4/7] Load raw from GCS (02_load_raw.sql)"
sed "s|__RAW_BUCKET__|${RAW_BUCKET}|g" sql/02_load_raw.sql | $Q

echo "==> [5/7] Build staging views + marts (03, 04)"
$Q < sql/03_staging.sql
$Q < sql/04_marts.sql

echo "==> [6/7] Build analytics views + run data-quality tests (05, 06)"
$Q < sql/05_analytics.sql
$Q < sql/06_tests.sql

echo "==> [7/7] Business-question answers"
for v in q1_blended_cpa_by_brand_month q2_top10_wow_spend_growth \
         q3_spend_vs_store_visits q4_budget_overspend_flags; do
  echo "----- marts.${v} -----"
  bq query --use_legacy_sql=false --project_id="$GCP_PROJECT_ID" --format=pretty --max_rows=15 \
    "SELECT * FROM marts.${v}"
done

echo "==> DONE. Datasets raw / staging / marts are live in ${GCP_PROJECT_ID}."
