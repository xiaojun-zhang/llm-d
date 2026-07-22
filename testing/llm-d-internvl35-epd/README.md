# InternVL3.5-30B-A3B SGLang E/PD on llm-d Kubernetes

This directory contains bringup assets for the llm-d run in namespace
`shared-infra`.

The assets are structured like the llm-d multimodal guides:

```text
router/*.values.yaml                 llm-d-router Helm values
modelserver/*/sglang/kustomization.yaml  llm-d modelserver overlays
scripts/*.sh                         validation, later deploy, smoke, bench
```

There is no standalone SGLang-only fallback path. Requests are intended to enter
through the llm-d router service, and modelserver pods join the llm-d
`InferencePool` by `llm-d.ai/guide` labels.

## Selected Cards

```text
H200 PD/1AGG: sc09dell06-nvd GPU 7
UUID:         GPU-5fd91b51-6253-0459-27bd-de55bb3e8ae6

B60 encoder0: sc09intel02-b60 XPU 0
PCI:          0000:18:00.0

B60 encoder1: sc09intel02-b60 XPU 1
PCI:          0000:1c:00.0
```

Card selection is encoded in local `ResourceClaimTemplate` resources. Those
templates do not reserve devices until the modelserver Deployments are applied
and pods create `ResourceClaim`s.

## Images

```text
GPU/PD image:
amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_gpu:477-e3682ee

XPU encoder image:
amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_xpu:509-5c58c0e
```

The XPU image was inspected previously:

```text
sglang      0.5.10.post2.dev2555+gc365795a1
sgl-kernel  0.11.0
torch       2.12.0+xpu
transformers 5.8.1
```

It contains the PR 26460 `resolve_max_seqlen` change and exposes
`--mm-attention-backend=xpu_attn`. The encoder manifests set that backend
explicitly.

## Topologies

`1AGG` uses:

```text
router/1agg.values.yaml
modelserver/1agg/sglang
```

It runs one SGLang aggregate worker on `sc09dell06-nvd` H200 GPU 7 and is routed by the llm-d
multimodal aggregation-style router profile.

`2E1PD` uses:

```text
router/2e1pd.values.yaml
modelserver/2e1pd/sglang
```

It runs two B60 XPU encoder pods and one H200 PD pod. The llm-d router profile
is the E/PD encode-disaggregation profile with `encode-filter` and
`decode-filter`; the decode pod includes the llm-d `routing-proxy` sidecar and
forwards requests to the SGLang language-only decode server.

Important caveat: upstream llm-d currently documents E/PD for vLLM/ECCPU, while
SGLang support in this repo is documented for token P/D. These manifests are
therefore the first SGLang-shaped llm-d E/PD bringup point. The SGLang process
still launches with native `--language-only`/`--encoder-only` flags and static
encoder URLs. llm-d-router v0.9.0's `ec-nixl` connector sends vLLM-style
OpenAI encoder requests and is not compatible with SGLang's native `/encode`
contract, so the sidecar is used as the router-facing proxy while SGLang handles
the encoder transfer path.
Smoke testing must prove that B70 encoder embeddings are actually used before
any performance comparison is valid.

## Validate Without Deploying

```bash
testing/llm-d-internvl35-epd/scripts/validate-manifests.sh
```

This renders both Kustomize overlays and runs `kubectl apply --dry-run=client`.
If `helm` is installed, it also templates both llm-d-router releases. If `helm`
is not installed, router template validation is skipped.

## Deploy Later

Run these only after reserving the H200/XPU cards:

```bash
testing/llm-d-internvl35-epd/scripts/deploy-1agg.sh
testing/llm-d-internvl35-epd/scripts/deploy-2e1pd.sh
```

The deploy scripts default `ROUTER_CREATE_INFERENCEPOOL=false` because the
current `shared-infra` service account can run the router and watch modelserver
pods, but cannot manage `InferencePool` CRs. Set
`ROUTER_CREATE_INFERENCEPOOL=true` only after that RBAC is granted.

Access goes through the llm-d router:

```bash
testing/llm-d-internvl35-epd/scripts/port-forward.sh 1agg
testing/llm-d-internvl35-epd/scripts/smoke-chat.sh

testing/llm-d-internvl35-epd/scripts/port-forward.sh 2e1pd
testing/llm-d-internvl35-epd/scripts/smoke-chat.sh
```

Probe benchmark after smoke passes:

```bash
testing/llm-d-internvl35-epd/scripts/bench-probe.sh 1agg 1.0 32
testing/llm-d-internvl35-epd/scripts/bench-probe.sh 2e1pd 1.0 32
```

Probe results default to:

```text
/home/h-zheng/robin/llm-d/testing/results/llm_d_internvl35_30b_a3b_k8s_probe_<timestamp>/
```

`bench-probe.sh` enables the local `bench_patches/sitecustomize.py` by default
because current SGLang still fails to construct the InternVL image benchmark
processor without it. Set `USE_BENCH_PATCHES=0` only after rechecking that the
installed SGLang benchmark client handles this InternVL snapshot natively. The
script also defaults `READY_CHECK_TIMEOUT_SEC=0` because the llm-d 2E1PD router
can return 404 for `/v1/models`; readiness is covered by the deploy rollout and
the benchmark's actual chat-completions requests.

The probe benchmark is a throughput workload, not a semantic correctness test.
It uses random JPEG images, random-token prompts, and short fixed output lengths;
`--output-details` can therefore show empty or meaningless text even when the
requests completed successfully. Use the deterministic semantic audit when the
question is whether the llm-d router and SGLang E/PD path are actually using
image inputs:

```bash
testing/llm-d-internvl35-epd/scripts/semantic-audit.sh 1agg
testing/llm-d-internvl35-epd/scripts/semantic-audit.sh 2e1pd
```

The audit sends fixed PNG inputs for color, OCR, shape, and multi-image ordering
checks and saves each image, reviewable request metadata, raw response, and JSON
summary under:

```text
/home/h-zheng/robin/llm-d/testing/results/llm_d_internvl35_30b_a3b_semantic_audit_<timestamp>/
```

`semantic-audit.sh` uses the explicit local InternVL model path by default
because `/v1/models` through the 2E1PD router can return 404. To run the audit
from a throwaway Docker client container, set `AUDIT_DOCKER_IMAGE=<image>`; the
container is launched with host networking and writes results through a bind
mount.

Cleanup:

```bash
testing/llm-d-internvl35-epd/scripts/delete.sh
```
