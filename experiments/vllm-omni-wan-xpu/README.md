# vLLM-Omni · Wan2.2 Text-to-Video on Intel XPU · llm-d orchestration

A reproducible experiment: serve a **Wan 2.2 text-to-video** diffusion model with the
**vLLM-Omni** backend on **Intel Arc B60** GPUs, both standalone and orchestrated under
**llm-d**, and a clear-eyed assessment of what llm-d does and does not buy you for this
workload.

> **Not a well-lit path (yet).** This lives under `experiments/` because llm-d has no
> diffusion/omni modelservice profile. The manifests here are hand-rolled to mirror the
> XPU well-lit paths (DRA GPU claims, istio gateway, InferencePool+EPP). See
> [ANALYSIS-llm-d-benefit.md](./ANALYSIS-llm-d-benefit.md) for the findings and the concrete
> changes that would turn this into a real well-lit path.

## TL;DR

- vLLM-Omni serves Wan2.2 T2V on Arc B60 cleanly (`vllm serve … --omni`, async `/v1/videos`).
- On 24 GB B60, `--vae-use-slicing --vae-use-tiling` are **required** (else OOM at higher res).
- llm-d **can** orchestrate it end-to-end (gateway → InferencePool → DRA-GPU pod, verified gens).
- But llm-d's differentiated value (KV-cache / prefix-cache / PD-disaggregation aware routing)
  is **inert** for diffusion — no KV cache, no prefix reuse, no prefill/decode split. What
  remains is the generic gateway + replica + GPU-scheduling chassis. Full reasoning + the
  fix (a diffusion-aware EPP scorer set + an omni modelservice profile) in the analysis doc.

## Model

The task said "Wan 2.2-T2V-14B". The real 14B T2V model is `Wan-AI/Wan2.2-T2V-A14B-Diffusers`
(MoE, 27B total / 14B active, ~126 GB). It did not fit the host disk alongside the image, so
this experiment serves the same-family `Wan-AI/Wan2.2-TI2V-5B-Diffusers` (34 GB). The serving
path, API, and every llm-d conclusion are identical; only weight size and minimum GPU count for
sharding differ.

## Files

| File | What |
|---|---|
| `build-and-serve.sh` | Build the XPU image from `docker/Dockerfile.xpu` and serve Wan2.2 (standalone docker) |
| `generate.sh` | Generate a video via `POST /v1/videos/sync`, report inference time |
| `k8s/01-deployment.yaml` | llm-d-style Deployment (vllm-omni image, `--omni`) + DRA `gpu.intel.com` claim + Service |
| `k8s/02-gateway.yaml` | istio `Gateway` + `HTTPRoute` fronting `/v1/videos` |
| `k8s/03-inferencepool.yaml` | `InferencePool` + EPP (`llm-d-inference-scheduler`) — with the diffusion caveat documented inline |
| `k8s/04-epp-rbac.yaml` | minimal RBAC so the EPP can watch the pool/pods |
| `ANALYSIS-llm-d-benefit.md` | the deliverable: benefit ledger + observed limitations + recommendations |

## Run — standalone

```bash
export HF_TOKEN=hf_...
./build-and-serve.sh          # build image + serve on GPU 0, port 8091
./generate.sh                 # writes wan_out.mp4
```

## Run — under llm-d (kind cluster `k8s-xpu`)

```bash
# Image into the node WITHOUT the kind-load double-copy (it can fill a shared disk):
docker save vllm-omni-xpu:local | \
  docker exec -i k8s-xpu-control-plane ctr -n k8s.io images import --no-unpack -

# (optional) share the host HF cache into the node via the node's /var volume + hostPath,
# instead of re-downloading the model — see ANALYSIS §5.

kubectl apply -f k8s/        # Deployment+DRA, Gateway+HTTPRoute, InferencePool+EPP, RBAC
kubectl -n llm-d rollout status deploy/wan-omni

# Test through the gateway:
kubectl -n llm-d port-forward svc/wan-omni-gateway-istio 18080:80 &
BASE_URL=http://localhost:18080 ./generate.sh
```

## Measured (1× Arc Pro B60, vLLM-Omni v0.22.0rc2.dev, Wan2.2-TI2V-5B)

| Resolution | Frames | Steps | Inference |
|---|---|---|---|
| 480×480 | 17 | 20 | 13.9 s |
| 480×832 | 17 | 20 | 24.5 s |
| 704×704 | 25 | 30 | 56.3 s |

Through the llm-d istio gateway: 480×480/17/20 = 13.9 s (parity with bare metal).

## Known limitations (all observed in this run)

- Multi-GPU (`--pipeline-parallel-size`/`--usp`) hangs in oneCCL warmup on Battlemage B60.
  Blocks sharding the A14B model today. Independent of llm-d.
- 24 GB VRAM is tight for video diffusion; VAE tiling/slicing mandatory above ~480p.
- The EPP needs RBAC (provided here) and, to be *useful*, a diffusion-aware scorer set
  (queue depth + VRAM headroom + steps-remaining) — see analysis §4.
