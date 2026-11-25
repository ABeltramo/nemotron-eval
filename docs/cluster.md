# Cluster

The evaluation runs on a ROSA (Red Hat OpenShift Service on AWS) cluster.

| Item | Value |
|---|---|
| Cluster | ROSA (hosted OpenShift) |
| OpenShift | 4.21 |
| RHOAI | 3.6.0 RC1 (`rhods-operator.3.6.0`) |
| Workers | 2x m5.4xlarge |
| GPU nodes | 2x g6e.2xlarge (NVIDIA L40S, 48 GB each) |
| GPU taint | `nvidia.com/gpu=true:NoSchedule` |

## Namespaces

| Namespace | Purpose |
|---|---|
| `redhat-ods-operator` | RHOAI operator (OLM) |
| `redhat-ods-applications` | EvalHub, TrustyAI operators, MLflow, dashboard |
| `llm-serving` | vLLM model deployments and the LiteLLM gateway |
| `evalhub-tenant` | tenant namespace where evaluation jobs run |
| `evalhub-postgres` | shared PostgreSQL, MariaDB and MinIO |

## EvalHub

RHOAI 3.6 ships EvalHub and the TrustyAI operators as operator-managed
components. The `EvalHub` CR `evalhub` in `redhat-ods-applications`
configures the deployment. The Garak provider
(`odh-trustyai-garak-lls-provider-dsp-rhel9`) is operator-managed and
provides the `garak` (non-KFP) and `garak-kfp` providers.

The EvalHub REST API is exposed through a reencrypt Route. Set the
route URL as `EVALHUB_URL` when running the scripts. Authentication
uses the OpenShift user token (`oc whoami -t`) plus the
`X-Tenant: evalhub-tenant` header on every request.

## Databases and tracking

Evaluation results are tracked in MLflow (experiment per job). The
shared PostgreSQL instance in `evalhub-postgres` backs EvalHub and
MLflow.

# Model serving

## Model under test

`nvidia-nemotron-nano-12b-v2-vl` runs in `llm-serving` as a single vLLM
Deployment on one g6e GPU node:

- Image: `docker.io/vllm/vllm-openai:latest`
- Weights: `nvidia/NVIDIA-Nemotron-Nano-12B-v2-VL-FP8` (FP8 quantization)
- `--max-model-len=131072`, `--max-num-seqs=8`,
  `--gpu-memory-utilization=0.90`, `--trust-remote-code`
- No `--reasoning-parser`: the v2 chat template pre-emits the think
  tags, so any tag-based parser misclassifies the whole answer as
  reasoning. Answers are served clean in `content`. Thinking can be
  requested per call with `chat_template_kwargs.enable_thinking`.
- Vision (image) input is supported.

## Attacker / judge / SDG model

`gemma-4-26b` runs in `llm-serving` on the second g6e GPU node. The
`intents` benchmark uses it for the attacker, judge, evaluator and SDG
(prompt generation) roles.

## LiteLLM gateway

Both models are exposed through the LiteLLM gateway in `llm-serving`:

The gateway route URL is set as `MODEL_URL` when running the scripts.

The gateway holds the shared upstream vLLM key; consumers authenticate
with per-user virtual keys. EvalHub jobs reference a Kubernetes Secret
in the tenant namespace that contains the gateway URL and the API keys
for each role (`judge_url`, `judge_api-key`, `attacker_api-key`,
`evaluator_api-key`, `sdg_url`, `sdg_api-key`). The secret name is
passed to the job as `model.auth.secret_ref`.

The secret is not part of this repository.
