#!/usr/bin/env bash
# Cancel an EvalHub evaluation job by resource ID.
#
# Usage:
#   ./stop-eval.sh <job-id>
#
# Requirements:
#   - oc logged in to the cluster (token is read via `oc whoami -t`)
#   - curl, jq
#
# Environment overrides:
#   EVALHUB_URL  EvalHub route (required)
#   TENANT       EvalHub tenant namespace (default: evalhub-tenant)

set -euo pipefail

JOB_ID="${1:?usage: stop-eval.sh <job-id>}"
EVALHUB_URL="${EVALHUB_URL:?set EVALHUB_URL to the EvalHub route}"
TENANT="${TENANT:-evalhub-tenant}"

TOKEN="$(oc whoami -t)"

echo "Cancelling job $JOB_ID..."
HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant: $TENANT" \
  "$EVALHUB_URL/api/v1/evaluations/jobs/$JOB_ID")

case "$HTTP_CODE" in
  204) echo "Cancelled." ;;
  404) echo "ERROR: job $JOB_ID not found (already deleted?)." >&2; exit 1 ;;
  *)   echo "ERROR: cancellation failed with HTTP $HTTP_CODE." >&2; exit 1 ;;
esac

# Show the resulting state.
sleep 3
curl -sk -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant: $TENANT" \
  "$EVALHUB_URL/api/v1/evaluations/jobs/$JOB_ID" \
  | jq -r '"state: \(.status.state)  (\(.status.message.message // "no message"))"'
