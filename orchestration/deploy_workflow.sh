#!/usr/bin/env bash
# =====================================================================
# orchestration/deploy_workflow.sh
# Deploys the Cloud Workflow and a daily Cloud Scheduler trigger.
# Alternative to scheduled_query.sh when you want step-level observability +
# test gating. Prereq: sql/99_production_procedures.sql installed.
# =====================================================================
set -euo pipefail
: "${GCP_PROJECT_ID:?set GCP_PROJECT_ID}"
REGION="${REGION:-us-central1}"
WF_NAME="media_analytics_daily"
SA="${GCP_PROJECT_ID}@appspot.gserviceaccount.com"   # or a dedicated SA

gcloud config set project "$GCP_PROJECT_ID" >/dev/null
gcloud services enable workflows.googleapis.com cloudscheduler.googleapis.com >/dev/null

echo "==> Deploy workflow"
gcloud workflows deploy "$WF_NAME" \
  --source=orchestration/workflow.yaml \
  --location="$REGION"

echo "==> Daily trigger at 08:00"
gcloud scheduler jobs create http "${WF_NAME}_trigger" \
  --location="$REGION" \
  --schedule="0 8 * * *" \
  --uri="https://workflowexecutions.googleapis.com/v1/projects/${GCP_PROJECT_ID}/locations/${REGION}/workflows/${WF_NAME}/executions" \
  --http-method=POST \
  --oauth-service-account-email="$SA" \
  2>/dev/null || echo "(scheduler job may already exist)"

echo "Done. Run manually with: gcloud workflows run ${WF_NAME} --location=${REGION}"
