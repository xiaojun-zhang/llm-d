# Serving Wan2.2 Text-to-Video with vLLM-Omni on Intel XPU — and the benefit of llm-d

**Date:** 2026-06-01
**Host:** 8× Intel Arc Pro B60 (Battlemage / `xe`), 24 GB each, Ubuntu 24.04, kernel 6.17
**Backend:** vLLM-Omni `v0.22.0rc2.dev` (XPU), torch `2.11.0+xpu`, vLLM `0.22.0+xpu`
**Model:** `Wan-AI/Wan2.2-TI2V-5B-Diffusers` (text-to-video diffusion, `WanPipeline`)
**Cluster:** kind `k8s-xpu`, istio gateway, DRA (`gpu.intel.com`), llm-d EPP `v0.8.0`

> Scope note. The request named "Wan 2.2-T2V-14B". The real 14B text-to-video model is
> `Wan-AI/Wan2.2-T2V-A14B-Diffusers` (MoE, 27B total / 14B active, ~126 GB on disk). It did
> not fit alongside the 28 GB serving image on the host's free disk (127 GB), so we served
> the smaller same-family `Wan2.2-TI2V-5B` (34 GB). The architecture, serving path, API, and
> every llm-d conclusion below are identical for the A14B model — only weight size and the
> minimum GPU count for sharding differ.

---

## 1. What was actually accomplished

1. **Built** the vLLM-Omni XPU image from `docker/Dockerfile.xpu` (Intel oneAPI 2025.3,
   compute-runtime 25.48, oneCCL 2021.15 w/ Battlemage support, triton-xpu 3.7.0). Verified
   all 8 B60s visible via `torch.xpu`.
2. **Served** Wan2.2-TI2V-5B with `vllm serve … --omni --enforce-eager --vae-use-slicing
   --vae-use-tiling` on a single B60.
3. **Generated** real videos through both the sync (`POST /v1/videos/sync`) and async job
   (`POST /v1/videos` → poll → `/content`) APIs. Latency on 1× B60:

   | Resolution | Frames | Steps | Inference time |
   |---|---|---|---|
   | 480×480 | 17 | 20 | **13.9 s** |
   | 480×832 | 17 | 20 | 24.5 s |
   | 704×704 | 25 | 30 | 56.3 s |

4. **Orchestrated it under llm-d** in the kind cluster: a modelservice-style `Deployment`
   (DRA `gpu.intel.com` claim, host HF-cache hostPath mount), `Service`, istio `Gateway` +
   `HTTPRoute`, and an `InferencePool` + EPP (`llm-d-inference-scheduler`). Generations
   verified end-to-end **through the Service (14.7 s) and through the istio Gateway (13.9 s)** —
   no measurable overhead vs. bare-metal docker.

So the model runs, and llm-d's deployment/gateway machinery genuinely fronts it. The
interesting result is *which parts of llm-d helped and which were inert*.

---

## 2. What llm-d is, and why the fit is partial

llm-d composes three layers per well-lit path:

| Layer | Component | Purpose |
|---|---|---|
| infra | `Gateway` + `HTTPRoute` (istio) | one stable L7 entrypoint, routing, TLS |
| **gaie** | **`InferencePool` + EPP** | **the inference scheduler — llm-d's crown jewel** |
| modelservice | `Deployment` of vLLM replicas | the serving endpoints + GPU plumbing |

The EPP's value is *LLM-token-aware routing*. The scorers it actually loaded in this run:

```
queue-scorer: 2.0
kv-cache-utilization-scorer: 2.0
prefix-cache-scorer: 3.0
```

These exist because token-generating LLMs have a **KV cache**, a reusable **prompt prefix**,
and a **decode queue** — and routing a request to the replica that already holds its prefix,
or away from a KV-saturated replica, is a large, measurable win.

**A text-to-video diffusion model has none of those primitives.** Wan2.2 runs a fixed-step
denoising loop over a latent; there is no KV cache, no autoregressive decode, no prompt-prefix
reuse across requests. It is also driven by a fundamentally different API surface:

| | LLM (what llm-d expects) | Wan2.2 T2V (what we served) |
|---|---|---|
| Endpoint | `POST /v1/chat/completions` | `POST /v1/videos` (async job) / `/v1/videos/sync` |
| Work unit | streaming tokens | one whole video, seconds–minutes |
| Reuse | KV cache + prefix | none |
| Scheduling signal | queue depth, KV %, prefix hit | queue depth only |

I confirmed this empirically. The diffusion pod's `/metrics` exposes
`vllm:omni_num_requests_running`, `vllm:omni_num_requests_waiting`, and
`vllm:omni_e2e_request_latency_s` — **but none of the `vllm:gpu_cache_usage` /
prefix-hit metrics the kv-cache and prefix scorers read.** So once wired up, the EPP scrapes
the endpoint, finds no KV/prefix signal, and **two of its three scorers have nothing to score
on** — it degrades to ~round-robin. And the InferencePool v1 API *requires* an
`endpointPickerRef`: llm-d structurally assumes every pool is fronted by an EPP, even when the
EPP has nothing useful to do.

---

## 3. The honest benefit ledger for *this* workload

### What llm-d genuinely gives you (works today)

- **Single gateway entrypoint + routing.** The istio `Gateway`/`HTTPRoute` cleanly front the
  `/v1/videos` API; verified a full generation through it. Real value: one address, TLS,
  path-based routing, namespace isolation — same as you'd want for any service.
- **Declarative multi-replica topology.** Scaling to N B60s is `replicas: N` + DRA claims;
  the InferencePool becomes the single Service abstraction over them. For an *embarrassingly
  parallel* workload like independent video jobs, plain fan-out across replicas is exactly the
  right scaling model, and llm-d expresses it cleanly.
- **GPU lifecycle via DRA.** The `gpu.intel.com` ResourceClaim integration worked unmodified —
  the pod got its Arc B60 and `torch.xpu.device_count()==1` inside the container.
- **Queue-depth load balancing (partial).** `vllm:omni_num_requests_waiting` *does* map to the
  EPP's `queue-scorer` concept. With a small adapter, the EPP could route to the
  least-busy replica — a genuine, if modest, win for long-running video jobs where a bad
  placement costs tens of seconds.
- **Operational surface.** Metrics/Prometheus (the cluster already runs `llm-d-monitoring`),
  rollout, health probing, the well-lit-path packaging conventions.

### What llm-d does **not** give you here (the crown jewel is inert)

- **KV-cache-aware routing** — no KV cache exists. Scorer is dead weight.
- **Prefix-cache-aware routing** — no prompt-prefix reuse. Scorer is dead weight.
- **PD (prefill/decode) disaggregation** — there is no prefill/decode split in diffusion;
  the whole denoise loop is one phase. llm-d's flagship disaggregation path simply does not
  apply.
- **Continuous batching / token-stream scheduling** — N/A for whole-video jobs.

### Net

For Wan2.2 T2V, **llm-d is useful as a deployment + gateway + GPU-scheduling chassis, but its
distinctive value — KV/prefix/PD-aware inference scheduling — does not apply.** Most of that
"chassis" value is available from plain Kubernetes + Gateway API; llm-d's *specific* advantage
over vanilla k8s is currently ~zero for this model, because that advantage lives entirely in
the EPP and the EPP has no diffusion signals to act on.

This is not a defect in the integration (it runs, end to end). It is a statement about
problem–tool fit: **llm-d is built for token-generation serving economics, and video
diffusion has a different cost structure.**

---

## 4. Where llm-d *could* add real value for diffusion — concrete asks

The integration boundary points directly at what would make llm-d genuinely valuable for
omni/diffusion workloads:

1. **A diffusion-aware scorer set.** Replace kv/prefix scorers with:
   - `queue-depth` (already emitted as `vllm:omni_num_requests_waiting`),
   - a `gpu-memory-headroom` scorer (place high-res/long jobs on replicas with VRAM to spare —
     directly relevant given the 24 GB B60 OOM we hit at 704×704 without VAE tiling),
   - a `step-throughput`/`steps-in-flight` scorer (denoise steps remaining ≈ ETA), so the
     picker can do shortest-remaining-time placement for long jobs.
2. **Async-job-aware routing.** `/v1/videos` returns a job ID and the client polls. The EPP
   should route the *create* call by load and pin the job's status/content GETs to the owning
   replica — today nothing guarantees that affinity.
3. **A modelservice profile for omni backends.** The `ms-*` values cascade has no diffusion
   profile; adding one (image `vllm-omni-*`, `--omni`, VAE flags, `/v1/videos` probes, the
   `vllm:omni_*` metric names) would make this a real well-lit path instead of a hand-rolled
   Deployment.
4. **Sequence/pipeline-parallel awareness for big models.** A14B needs sharding across GPUs.
   vLLM-Omni supports `--pipeline-parallel-size` / `--usp` (Ulysses SP); llm-d's topology
   would need to express multi-GPU-per-replica claims (and the oneCCL-on-Battlemage issue
   below must be solved first).

---

## 5. Caveats / limitations observed

- **24 GB B60 is tight for video diffusion.** 704×704/25-frame OOM'd (`xe [drm] VM worker
  error: -12` = ENOMEM) until `--vae-use-slicing --vae-use-tiling` were enabled (these are
  engine CLI flags, matching the upstream Intel Arc B70 recipe). With tiling, the same shape
  succeeds. The A14B model would *require* multi-GPU sharding on these cards.
- **Multi-GPU (PP=2/TP) hangs on oneCCL.** Both workers loaded, but the warmup all-reduce hung
  (`CCL_WARN: did not find MPI-launcher`); `CCL_ZE_IPC_EXCHANGE=pidfd` didn't fix it. This is a
  Battlemage/oneCCL maturity gap, independent of llm-d, and blocks A14B sharding today.
- **Disk pressure on a shared host.** `kind load docker-image` (double-copy) filled the disk to
  100%; the working path was a *streamed* `docker save | ctr images import --no-unpack` plus
  hardlinking the model into the node volume (same filesystem → zero extra bytes).
- **EPP needs RBAC + a metric adapter.** Out of the box the EPP couldn't watch the pool (no
  RBAC) and, once it could, found no LLM metrics. Both are fixable; both show the
  LLM-shaped assumptions baked into the gaie layer.

---

## 6. One-paragraph answer

vLLM-Omni serves Wan2.2 text-to-video on Intel Arc B60 cleanly, and llm-d *can* orchestrate it
— we ran real generations through the full istio-Gateway → InferencePool → DRA-GPU pod path
with no overhead. But the benefit llm-d brings here is the generic one (a gateway, declarative
replicas, GPU scheduling via DRA, metrics) rather than its differentiated one: the EPP's
KV-cache / prefix-cache / PD-disaggregation routing is inert because a diffusion model has no
KV cache, no reusable prefix, and no prefill/decode split, and is driven by an async
`/v1/videos` job API instead of `/v1/chat/completions`. The clear, actionable win would be a
diffusion-aware EPP scorer set (queue depth + VRAM headroom + steps-remaining) plus an
omni modelservice profile — at which point llm-d would offer video serving the same kind of
intelligent, load-aware routing it gives token LLMs today.
