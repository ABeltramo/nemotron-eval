# Evaluation of NVIDIA-Nemotron-Nano-12B-v2-VL-FP8

This repository records the red-teaming and safety evaluation of
`nvidia/NVIDIA-Nemotron-Nano-12B-v2-VL-FP8`, and provides everything
needed to re-run the same evaluations on a compatible cluster.

The goal is to produce red-teaming evidence for a model catalog
submission: Garak scans with per-probe Attack Success Rate (ASR) and
per-prompt response detail.

## What is evaluated

| Item | Value |
|---|---|
| Model under test | `nvidia/NVIDIA-Nemotron-Nano-12B-v2-VL-FP8` |
| Served as | `nvidia-nemotron-nano-12b-v2-vl` |
| Serving stack | vLLM (`vllm-openai:latest`), 1x g6e.2xlarge GPU, TP=1 |
| Access path | LiteLLM gateway (per-user keys, shared upstream key) |
| Attacker / judge / SDG model | `gemma-4-26b` (same cluster, separate GPU) |
| Evaluation framework | RHOAI 3.6 EvalHub + Garak provider (`garak`, non-KFP mode) |

## Repository layout

```
docs/       cluster and deployment documentation
scripts/    runnable evaluation scripts (EvalHub REST API)
results/    recorded outputs, one directory per evaluation run
```

## Quick start

Requirements: `oc` logged in to the cluster as a user that can submit
EvalHub jobs in the `evalhub-tenant` namespace, plus `curl`, `jq` and
`python3`.

```bash
export EVALHUB_URL=<evalhub route>   # see docs/cluster.md
export MODEL_SECRET=<model auth secret name>
./scripts/run-eval.sh intents
```

The script submits the `intents` benchmark and waits for completion.
See `docs/evaluation.md` for the request format and parameters.

## Benchmarks

| Benchmark | Status | Purpose |
|---|---|---|
| `intents` | done | context-aware red teaming with attacker/judge models (most complex) |
| `quality` | done | violence, profanity, toxicity, hate speech, integrity |
| `quick` | done (smoke test) | single DAN probe, verifies the end-to-end chain |

## Findings

The full rollup lives in [`results/VULNERABILITY-OVERVIEW.md`](results/VULNERABILITY-OVERVIEW.md),
with per-run detail in each `results/<date>-<benchmark>/metrics.md`.

Two phases were evaluated:

1. **Generic pass** (`quality` benchmark, 85 hardcoded probes, 12,987
   examples): overall ASR **21.3%**. Weakest areas: latent prompt injection
   (54–77%), prompt hijacking (69–73%), package hallucination (up to 43%),
   false-premise acceptance (45%). Strong areas: explicit toxicity, API-key
   leakage, memorized-content completion, Base-encoding payloads.
2. **Automated red teaming** (`intents` benchmark, SPO/Translation/TAP over
   8 custom harm categories, 80 generated adversarial prompts): overall ASR
   **96.3%** — every category compromised at 80–100%.

Headline conclusion: the model resists *known* attack corpora (~21%) but not
*novel* generated ones (~96%). Instruction-following overrides safety — the
injection family is both the biggest phase-1 weakness and the mechanism the
phase-2 stubs exploit. Self-harm, hate speech and fraud categories are fully
compromised by automated red teaming.

Browsable HTML reports:

- [quality — garak report](results/2026-11-25-quality/artifacts/scan.report.html)
- [intents — intent dashboard](results/2026-11-24-intents-tap-tuned/artifacts/scan.intents.html)

## Results

Each run is recorded under `results/<date>-<benchmark>/` with the raw
API response, the extracted metrics and a short summary. See
`results/` for what exists so far.

No credentials are stored in this repository. Scripts read the cluster
token from `oc whoami -t` at runtime.
