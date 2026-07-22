# Kimi-VL-A3B-Instruct SGLang E/PD on llm-d Kubernetes

This directory contains llm-d Kubernetes bringup assets for testing
`moonshotai/Kimi-VL-A3B-Instruct` in namespace `shared-infra`.

The harness mirrors the InternVL3.5 E/PD layout but removes the
InternVL-specific SGLang runtime and benchmark patches. Kimi-VL is supported
directly by the SGLang images used here.

## Verified Inputs

Model snapshot:

```text
/mnt/weka/data/llm-d-models-pv/hub/models--moonshotai--Kimi-VL-A3B-Instruct/snapshots/main
```

The snapshot should contain `config.json`, `preprocessor_config.json`,
`model.safetensors.index.json`, and the model `*.safetensors` shards.

GPU/PD image:

```text
amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_gpu:477-e3682ee
```

XPU encoder image:

```text
amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_xpu:509-5c58c0e
```

The XPU image was inspected through Kubernetes imagePullSecrets and includes:

```text
sglang      0.5.10.post2.dev2555+gc365795a1
sgl-kernel  0.11.0
torch       2.12.0+xpu
transformers 5.8.1
KimiVLForConditionalGeneration, encoder_only/language_only, xpu_attn
```

## Selected Cards

```text
H200 PD/1AGG: sc09super21-h200 GPU 7
UUID:         GPU-5566797f-f7a9-dac4-32c7-f2f0ea80a1f7

B60 encoder0: sc09intel02-b60 XPU 0
PCI:          0000:18:00.0

B60 encoder1: sc09intel02-b60 XPU 1
PCI:          0000:1c:00.0

B60 encoder2: sc09intel02-b60 XPU 2
PCI:          0000:54:00.0

B60 encoder3: sc09intel02-b60 XPU 3
PCI:          0000:58:00.0
```

Card selection is encoded by local `ResourceClaimTemplate` resources. Applying
the modelserver overlays creates `ResourceClaim`s and reserves the cards.

## Topologies

`1AGG`:

```text
router/1agg.values.yaml
modelserver/1agg/sglang
```

`2E1PD`:

```text
router/2e1pd.values.yaml
modelserver/2e1pd/sglang
```

`4E1PD`:

```text
router/4e1pd.values.yaml
modelserver/4e1pd/sglang
```

The 2E1PD decode pod uses SGLang `--language-only` with static encoder URLs.
The XPU encoder pods use:

```text
--encoder-only
--enable-multimodal
--mm-attention-backend=xpu_attn
--encoder-transfer-backend=zmq_to_scheduler
```

The 2E1PD encoder pods also apply
`modelserver/2e1pd/sglang/patch_kimi_epd_runtime.py` at container startup.
This runtime patch fixes two SGLang Kimi-VL E/PD issues in the tested image:

```text
Kimi-VL image grids are 2-D (h, w), while SGLang's batched encoder helper
assumed Qwen-style 3-D (t, h, w) grids.

Kimi-VL grid metadata from the encoder must be converted away from NumPy
objects before pickling, otherwise the decode side safe unpickler rejects it.
```

## Validate Without Deploying

```bash
PATH=/tmp/llmd-helm:$PATH \
  testing/llm-d-kimivla3b-epd/scripts/validate-manifests.sh
```

## Deploy, Smoke, Benchmark

Run only after reserving the target cards.

```bash
export PATH=/tmp/llmd-helm:$PATH
export NAMESPACE=shared-infra

testing/llm-d-kimivla3b-epd/scripts/deploy-1agg.sh
testing/llm-d-kimivla3b-epd/scripts/port-forward.sh 1agg
testing/llm-d-kimivla3b-epd/scripts/smoke-chat.sh
testing/llm-d-kimivla3b-epd/scripts/bench-probe.sh 1agg 1.0 8
testing/llm-d-kimivla3b-epd/scripts/delete.sh

testing/llm-d-kimivla3b-epd/scripts/deploy-2e1pd.sh
testing/llm-d-kimivla3b-epd/scripts/port-forward.sh 2e1pd
testing/llm-d-kimivla3b-epd/scripts/smoke-chat.sh
testing/llm-d-kimivla3b-epd/scripts/bench-probe.sh 2e1pd 1.0 8
testing/llm-d-kimivla3b-epd/scripts/delete.sh
```

The random probe uses the same image workload shape as the InternVL matrix:

```text
dataset:          image
image-count:      8 by default
image-resolution: 1080p by default
random-input-len: 128
random-output-len: 16
max-concurrency:  8
backend:          sglang-oai-chat
```

For Kimi-VL on the current single-H200 1AGG setup, the full `8 x 1080p`
shape OOMs during benchmark warmup. Use a smaller common shape for a meaningful
1AGG versus 2E1PD comparison, for example:

```bash
export IMAGE_COUNT=1
export IMAGE_RESOLUTION=1080p
export RANDOM_INPUT_LEN=128
export RANDOM_OUTPUT_LEN=16
export MAX_CONCURRENCY=8

testing/llm-d-kimivla3b-epd/scripts/bench-probe.sh 1agg 1.0 8
testing/llm-d-kimivla3b-epd/scripts/bench-probe.sh 2e1pd 1.0 8
```

If encoders are restarted while decode remains running, restart the decode
deployment before smoke/benchmark. The decode process can evict static encoder
URLs after health-check failures and then process requests without encoder
disaggregation.

Probe results default to:

```text
/home/h-zheng/robin/llm-d/testing/results/llm_d_kimivla3b_k8s_probe_<timestamp>/
```

Cleanup:

```bash
testing/llm-d-kimivla3b-epd/scripts/delete.sh
```
