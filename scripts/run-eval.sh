#!/usr/bin/env bash
# Submit a Garak evaluation to EvalHub, wait for it to finish, and download
# the result artifacts from MLflow.
#
# Usage:
#   ./run-eval.sh <benchmark-id> [run-name]
#
# Examples:
#   ./run-eval.sh quick
#   ./run-eval.sh intents
#   ./run-eval.sh owasp_llm_top10
#
# Requirements:
#   - oc logged in to the cluster (token is read via `oc whoami -t`)
#   - curl, jq
#   - The model auth secret referenced below must exist in the tenant
#     namespace and contain the gateway URL and per-role API keys
#     (see docs/evaluation.md).
#   - MLflow running in the cluster (the script port-forwards to it).
#
# Environment overrides:
#   EVALHUB_URL    EvalHub route (required)
#   TENANT         EvalHub tenant namespace (default: evalhub-tenant).
#                  Also used as the MLflow workspace: job pods send
#                  X-MLFLOW-WORKSPACE = tenant namespace, and the
#                  redhat-ods-* namespaces are excluded from MLflow
#                  workspaces by the kubernetes workspace provider.
#   MODEL_NAME     model under test (default: nvidia-nemotron-nano-12b-v2-vl)
#   ATTACKER_MODEL model used for judge/attacker/evaluator/sdg roles
#                  (default: gemma-4-26b)
#   MODEL_SECRET   model auth secret name in the tenant namespace
#                  (default: read from $MODEL_SECRET_NAME, no fallback)
#   MODEL_URL      gateway URL (required)
#   MLFLOW_NS      namespace of the MLflow service
#                  (default: redhat-ods-applications)

set -euo pipefail

BENCHMARK_ID="${1:?usage: run-eval.sh <benchmark-id> [run-name]}"
RUN_NAME="${2:-${MODEL_NAME:-nvidia-nemotron-nano-12b-v2-vl}-${BENCHMARK_ID}-$(date +%Y%m%d-%H%M%S)}"

EVALHUB_URL="${EVALHUB_URL:?set EVALHUB_URL to the EvalHub route}"
TENANT="${TENANT:-evalhub-tenant}"
MODEL_NAME="${MODEL_NAME:-nvidia-nemotron-nano-12b-v2-vl}"
ATTACKER_MODEL="${ATTACKER_MODEL:-gemma-4-26b}"
MODEL_SECRET="${MODEL_SECRET:-${MODEL_SECRET_NAME:?set MODEL_SECRET to the model auth secret name}}"
MODEL_URL="${MODEL_URL:?set MODEL_URL to the model gateway URL}"
MLFLOW_NS="${MLFLOW_NS:-redhat-ods-applications}"

TOKEN="$(oc whoami -t)"

# Benchmark parameters. Two sources, both optional:
#   PARAMS_FILE  - JSON file with the full benchmark "parameters" object
#                  (use for custom garak_config overrides)
#   ATTACKER_MODEL - for the intents benchmark, auto-fills the
#                  judge/attacker/evaluator/sdg role model names (URLs and
#                  keys come from the model auth secret)
PARAMS="{}"
if [ -n "${PARAMS_FILE:-}" ] && [ -f "$PARAMS_FILE" ]; then
  PARAMS=$(cat "$PARAMS_FILE")
elif [ "$BENCHMARK_ID" = "intents" ]; then
  PARAMS=$(printf '{
    "intents_models": {
      "judge":     {"name": "%s"},
      "attacker":  {"name": "%s"},
      "evaluator": {"name": "%s"},
      "sdg":       {"name": "%s"}
    }
  }' "$ATTACKER_MODEL" "$ATTACKER_MODEL" "$ATTACKER_MODEL" "$ATTACKER_MODEL")
fi

echo "Submitting benchmark '$BENCHMARK_ID' against '$MODEL_NAME' (run: $RUN_NAME)..."

RESPONSE=$(curl -sk -X POST "$EVALHUB_URL/api/v1/evaluations/jobs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Tenant: $TENANT" \
  -d @- <<EOF
{
  "name": "$RUN_NAME",
  "model": {
    "url": "$MODEL_URL",
    "name": "$MODEL_NAME",
    "auth": {
      "secret_ref": "$MODEL_SECRET"
    }
  },
  "benchmarks": [{
    "id": "$BENCHMARK_ID",
    "provider_id": "garak",
    "parameters": $PARAMS
  }],
  "experiment": {
    "name": "$RUN_NAME"
  }
}
EOF
)

JOB_ID=$(echo "$RESPONSE" | jq -r '.resource.id')
if [ -z "$JOB_ID" ] || [ "$JOB_ID" = "null" ]; then
  echo "ERROR: job submission failed:"
  echo "$RESPONSE" | jq .
  exit 1
fi
RESULT_DIR="results/$(date +%Y-%m-%d)-${BENCHMARK_ID}"
mkdir -p "$RESULT_DIR"
echo "$RESPONSE" | jq . > "$RESULT_DIR/submit.json"
echo "Job submitted: $JOB_ID"

# ---------------------------------------------------------------------------
# MLflow artifact download
#
# The garak provider uploads the scan artifacts (scan.report.jsonl,
# scan.hitlog.jsonl, scan.intents.html, scan.report.html, sample_results.jsonl,
# SDG CSVs) to the MLflow run created for the job. The MLflow server has
# workspaces enabled: each workspace maps to a Kubernetes namespace, and the
# job pods send X-MLFLOW-WORKSPACE = tenant namespace. Artifacts are served
# through the --serve-artifacts proxy endpoint.
# ---------------------------------------------------------------------------
download_mlflow_artifacts() {
  local exp_id run_id
  exp_id=$(echo "$STATUS_JSON" | jq -r '.resource.mlflow_experiment_id // empty')
  run_id=$(echo "$STATUS_JSON" | jq -r '.results.benchmarks[0].mlflow_run_id // empty')
  if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
    echo "No MLflow run id in job status — cannot download artifacts."
    return 1
  fi
  [ -z "$exp_id" ] && exp_id=$(echo "$STATUS_JSON" | jq -r '.status.benchmarks[0].mlflow_experiment_id // empty')

  local port=18500
  oc port-forward -n "$MLFLOW_NS" svc/mlflow "$port:8443" >/dev/null 2>&1 &
  local pf_pid=$!
  sleep 8

  local base="https://localhost:$port/mlflow"
  local auth=(-sk -H "Authorization: Bearer $TOKEN" -H "X-MLFLOW-WORKSPACE: $TENANT")

  # List what the run actually has, then download each file.
  local files
  files=$(curl "${auth[@]}" "$base/api/2.0/mlflow/artifacts/list?run_id=$run_id" \
    | jq -r '.files[]?.path' 2>/dev/null)
  if [ -z "$files" ]; then
    echo "MLflow reported no artifacts for run $run_id."
    kill $pf_pid 2>/dev/null || true
    return 1
  fi

  local artdir="$RESULT_DIR/artifacts"
  mkdir -p "$artdir"
  for f in $files; do
    curl "${auth[@]}" \
      "$base/api/2.0/mlflow-artifacts/artifacts/workspaces/$TENANT/$exp_id/$run_id/artifacts/$f" \
      -o "$artdir/$f"
    echo "  saved $f ($(stat -c%s "$artdir/$f" 2>/dev/null || stat -f%z "$artdir/$f") bytes)"
  done
  kill $pf_pid 2>/dev/null || true
  echo "Artifacts saved to $artdir"
}

# ---------------------------------------------------------------------------
# Wait loop
#
# Follows the job pod log (garak progress bars) directly, like `oc logs -f`,
# while polling the job state separately and printing only state changes.
# ---------------------------------------------------------------------------
POLL_INTERVAL="${POLL_INTERVAL:-2}"
LOG_PID=""
LAST_STATE=""
cleanup() {
  if [ -n "$LOG_PID" ]; then
    # Kill the stream subshell first (stops it respawning oc logs), then its
    # children (oc logs / grep / sed) — killing only the subshell leaves the
    # pipeline members streaming to the terminal after Ctrl+C.
    kill "$LOG_PID" 2>/dev/null || true
    pkill -P "$LOG_PID" 2>/dev/null || true
  fi
}
trap cleanup INT TERM EXIT

# Follow the adapter container log and print garak progress lines as they
# arrive. `oc logs -f` fails instantly if the container is not ready yet, so
# retry until the stream stays up; the loop is killed by the EXIT trap.
start_log_stream() {
  (
    # The main script runs `set -euo pipefail`; a failed `oc logs` (container
    # not ready yet) would otherwise errexit this subshell and kill the
    # stream permanently, so errexit/pipefail are disabled here.
    set +e +o pipefail
    while true; do
      oc logs -n "$TENANT" "$POD" -c adapter -f 2>/dev/null \
        | grep --line-buffered 'garak\[progress\]' \
        | sed -u -E 's/^.*garak\[progress\] //' \
        | sed -u -E $'s/\x1b\[[0-9;]*[mK]//g' || true
      sleep 2
    done
  ) &
  LOG_PID=$!
}

echo "Waiting for completion (polling every ${POLL_INTERVAL}s)..."
POD=""
while true; do
  sleep "$POLL_INTERVAL"
  STATUS_JSON=$(curl -sk -H "Authorization: Bearer $TOKEN" \
    -H "X-Tenant: $TENANT" \
    "$EVALHUB_URL/api/v1/evaluations/jobs/$JOB_ID")
  STATE=$(echo "$STATUS_JSON" | jq -r '.status.state')

  # Locate the job pod once it exists, then start following its log.
  if [ -z "$POD" ]; then
    POD=$(oc get pods -n "$TENANT" -o name 2>/dev/null | grep "${JOB_ID:0:20}" | head -1 | cut -d/ -f2) || true
    [ -n "$POD" ] && start_log_stream
  fi

  # Print state changes only; garak progress flows from the log stream.
  if [ "$STATE" != "$LAST_STATE" ]; then
    printf '[%s] state: %s\n' "$(date +%H:%M:%S)" "$STATE"
    LAST_STATE=$STATE
  fi

  case "$STATE" in
    completed)
      echo "$STATUS_JSON" | jq . > "$RESULT_DIR/job.json"
      echo "Done. Job response saved to $RESULT_DIR/job.json"
      echo "$STATUS_JSON" | jq '.status.benchmarks'
      echo "Downloading artifacts from MLflow..."
      download_mlflow_artifacts || echo "WARNING: artifact download failed; per-call detail not saved."
      exit 0
      ;;
    failed|error|cancelled)
      echo "$STATUS_JSON" | jq . > "$RESULT_DIR/job.json"
      echo "Job ended in state: $STATE"
      echo "$STATUS_JSON" | jq '.status.message'
      exit 1
      ;;
  esac
done
