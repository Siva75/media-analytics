#!/usr/bin/env bash
# =====================================================================
# orchestration/scheduled_query.sh
# Simplest production scheduling: a BigQuery Scheduled Query that runs the whole
# pipeline daily by CALLing the stored procedure. No Airflow/Composer needed.
#
# Prereq: sql/99_production_procedures.sql already installed (deploy_prod.sh).
# =====================================================================
set -euo pipefail
: "${GCP_PROJECT_ID:?set GCP_PROJECT_ID}"
LOCATION="${BQ_LOCATION:-US}"

bq mk --transfer_config \
  --project_id="$GCP_PROJECT_ID" \
  --location="$LOCATION" \
  --data_source=scheduled_query \
  --display_name="media_analytics_daily" \
  --schedule="every 24 hours" \
  --params='{"query":"CALL marts.sp_run_pipeline();"}'

echo "Scheduled query created. It runs CALL marts.sp_run_pipeline() daily."
echo "View/edit it under BigQuery > Scheduled queries in the console."
