# SGLang + llm-d InternVL3.5 E/PD Disaggregation Reproduction Notes

This file captures the setup used for the llm-d Kubernetes InternVL3.5-30B-A3B
matched `1AGG` versus `2E1PD` tests. It is intended as a handoff for a future
operator or code agent to reproduce both the random image benchmark and the MMMU
semantic checks without relying on chat history.

The matching Dynamo runbook is:

```text
https://github.com/xiaojun-zhang/dynamo/blob/sglang-summit-e-pd-disaggregation-demo/testing/SGLANG_DYNAMO_PD_DISAGGREGATION_INTERNVL35.md
```

## Result To Reproduce

Model:

```text
/mnt/weka/data/llm-d-models-pv/hub/models--OpenGVLab--InternVL3_5-30B-A3B/snapshots/main
```

Final random benchmark workload:

```text
topologies:       1AGG and 2E1PD
rates:            0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0
num-prompts:      128
image-count:      8
image-resolution: 1080p
random-input-len: 128
random-output-len: 16
max-concurrency:  8
seed:             0
backend:          sglang-oai-chat
dataset:          image
```

Result folder used for the benchmark table in this file:

```text
/home/h-zheng/robin/llm-d/testing/results/llm_d_internvl35_30b_a3b_k8s_matrix_20260708_185011_n128
```

MMMU semantic check result folders:

```text
/home/h-zheng/robin/llm-d/testing/results/llm_d_internvl35_30b_a3b_mmmu_semantic_cs_20260709_084013
/home/h-zheng/robin/llm-d/testing/results/llm_d_internvl35_30b_a3b_mmmu_semantic_20260709_082417_3case
```

## Repository Assets

Run from:

```bash
cd /home/h-zheng/robin/llm-d
```

Main files:

```text
testing/llm-d-internvl35-epd/README.md
testing/llm-d-internvl35-epd/router/1agg.values.yaml
testing/llm-d-internvl35-epd/router/2e1pd.values.yaml
testing/llm-d-internvl35-epd/modelserver/1agg/sglang
testing/llm-d-internvl35-epd/modelserver/2e1pd/sglang
testing/llm-d-internvl35-epd/scripts/deploy-1agg.sh
testing/llm-d-internvl35-epd/scripts/deploy-2e1pd.sh
testing/llm-d-internvl35-epd/scripts/port-forward.sh
testing/llm-d-internvl35-epd/scripts/bench-probe.sh
testing/llm-d-internvl35-epd/scripts/audit-mmmu-correctness.py
testing/llm-d-internvl35-epd/scripts/delete.sh
testing/llm-d-internvl35-epd/bench_patches/sitecustomize.py
```

There is no standalone SGLang-only fallback path. Requests enter through the
llm-d router service and are routed to SGLang modelserver pods.

## Kubernetes Namespace And Helm

The tests run in:

```text
namespace: shared-infra
kubeconfig: ~/.kube/config
```

The deploy scripts require `helm`. In this environment, use:

```bash
export PATH=/tmp/llmd-helm:$PATH
export NAMESPACE=shared-infra
```

The deploy scripts default `ROUTER_CREATE_INFERENCEPOOL=false` because the
current service account can run the router and watch modelserver pods, but
cannot manage `InferencePool` CRs.

## Machines And Cards

H200 GPU host:

```text
hostname: sc09dell06-nvd
GPU type: NVIDIA H200 NVL
used card: GPU 7
UUID:      GPU-5fd91b51-6253-0459-27bd-de55bb3e8ae6
```

XPU host:

```text
hostname: sc09intel02-b60
used cards: XPU 0 and XPU 1
XPU 0 PCI: 0000:18:00.0
XPU 1 PCI: 0000:1c:00.0
```

Card placement is encoded in the local Kubernetes `ResourceClaimTemplate`
resources. The templates do not reserve devices until the modelserver
Deployments are applied and pods create `ResourceClaim`s.

Before testing, make sure there are no leftover llm-d resources:

```bash
kubectl get deploy,pod,svc,resourceclaim,resourceclaimtemplate -n shared-infra -o wide
ps -ef | rg 'kubectl port-forward|bench-probe|sglang.bench_serving|audit-mmmu'
docker ps --format 'table {{.ID}}\t{{.Status}}\t{{.Names}}\t{{.Command}}' | rg 'bench|audit|mmmu|NAMES'
```

## Docker Images

GPU/PD image:

```text
amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_gpu:477-e3682ee
```

XPU encoder image:

```text
amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_xpu:509-5c58c0e
```

The XPU image was inspected during bringup:

```text
sglang       0.5.10.post2.dev2555+gc365795a1
sgl-kernel   0.11.0
torch        2.12.0+xpu
transformers 5.8.1
```

It contains the SGLang PR 26460 `resolve_max_seqlen` change and exposes
`--mm-attention-backend=xpu_attn`. The encoder manifests set this backend
explicitly.

## Topologies

### 1AGG

`1AGG` uses:

```text
router/1agg.values.yaml
modelserver/1agg/sglang
```

It runs one SGLang aggregate worker on `sc09dell06-nvd` GPU 7. The worker does
image encode, prefill, and decode in one process.

Key SGLang settings:

```text
--model-path=/mnt/weka/data/llm-d-models-pv/hub/models--OpenGVLab--InternVL3_5-30B-A3B/snapshots/main
--served-model-name=OpenGVLab/InternVL3_5-30B-A3B
--enable-multimodal
--chat-template=internvl-2-5
--dtype=auto
--kv-cache-dtype=fp8_e4m3
--tensor-parallel-size=1
--mem-fraction-static=0.80
--max-running-requests=32
--chunked-prefill-size=65536
--max-prefill-tokens=65536
--max-total-tokens=250000
--cuda-graph-max-bs=32
--page-size=16
```

### 2E1PD

`2E1PD` uses:

```text
router/2e1pd.values.yaml
modelserver/2e1pd/sglang
```

It runs:

```text
encoder 0: sc09intel02-b60 XPU 0
encoder 1: sc09intel02-b60 XPU 1
decode:    sc09dell06-nvd GPU 7
```

The llm-d router profile uses the multimodal disaggregation path:

```text
disagg-headers-handler
always-disagg-multimodal-decider
disagg-profile-handler
encode-filter
decode-filter
```

The decode pod includes the llm-d `routing-proxy` sidecar, but SGLang handles
the encoder transfer path with native static encoder URLs:

```text
--language-only
--encoder-transfer-backend=zmq_to_scheduler
--encoder-urls \
  http://llmd-internvl35-2e1pd-sglang-encode-0.shared-infra.svc.cluster.local:8000 \
  http://llmd-internvl35-2e1pd-sglang-encode-1.shared-infra.svc.cluster.local:8000
```

The XPU encoders use:

```text
--encoder-only
--enable-multimodal
--mm-attention-backend=xpu_attn
--encoder-transfer-backend=zmq_to_scheduler
```

Important startup fix:

```text
modelserver/2e1pd/sglang/patch-decode.yaml
```

contains a `wait-encoders` init container. It waits for both encoder `/health`
endpoints before SGLang decode starts. Without this, decode can start first,
evict both encoder URLs after health-check failures, and later fall back to a
local vision path that crashes because the language-only decode model has no
`vision_model`.

Validate this after deploying 2E1PD:

```bash
kubectl get pod -n shared-infra -l llm-d.ai/role=decode \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.initContainerStatuses[*]}{.name}{":"}{.state.terminated.reason}{":"}{.ready}{"\n"}{end}{end}'

kubectl logs -n shared-infra deploy/llmd-internvl35-2e1pd-sglang-encode-0 -c modelserver | rg 'Using xpu_attn'
kubectl logs -n shared-infra deploy/llmd-internvl35-2e1pd-sglang-encode-1 -c modelserver | rg 'Using xpu_attn'
```

## Benchmark Client

`testing/llm-d-internvl35-epd/scripts/bench-probe.sh` is the source of truth
for the random benchmark client. It runs:

```bash
python3 -m sglang.bench_serving \
  --model /mnt/weka/data/llm-d-models-pv/hub/models--OpenGVLab--InternVL3_5-30B-A3B/snapshots/main \
  --backend sglang-oai-chat \
  --host 127.0.0.1 \
  --port 8000 \
  --ready-check-timeout-sec 0 \
  --dataset-name image \
  --num-prompts <NUM_PROMPTS> \
  --random-input-len 128 \
  --random-output-len 16 \
  --image-count 8 \
  --image-resolution 1080p \
  --request-rate <RATE> \
  --apply-chat-template \
  --seed 0 \
  --disable-tqdm \
  --output-file <OUT_JSON> \
  --max-concurrency 8
```

The script enables:

```text
PYTHONPATH=testing/llm-d-internvl35-epd/bench_patches
```

by default. Keep this enabled. Current SGLang still needs the
`sitecustomize.py` fallback to construct the InternVL image benchmark
processor reliably.

`READY_CHECK_TIMEOUT_SEC=0` is intentional. The llm-d EPP router can return
404 for `/v1/models`; readiness is covered by Kubernetes rollout plus actual
chat-completion requests.

## Single-Rate Random Benchmark Reproduction

Run 1AGG:

```bash
cd /home/h-zheng/robin/llm-d
export PATH=/tmp/llmd-helm:$PATH
export NAMESPACE=shared-infra

RESULT_ROOT=/home/h-zheng/robin/llm-d/testing/results/manual_llmd_internvl35_$(date +%Y%m%d_%H%M%S)
mkdir -p "${RESULT_ROOT}"

NAMESPACE=shared-infra testing/llm-d-internvl35-epd/scripts/deploy-1agg.sh \
  2>&1 | tee "${RESULT_ROOT}/deploy_1agg.log"

NAMESPACE=shared-infra LOCAL_PORT=8000 \
  testing/llm-d-internvl35-epd/scripts/port-forward.sh 1agg \
  >"${RESULT_ROOT}/port_forward_1agg.log" 2>&1 &
PF_PID=$!
sleep 3

docker run --rm --network host --entrypoint /bin/bash \
  -v /home/h-zheng/robin/llm-d:/home/h-zheng/robin/llm-d:ro \
  -v /home/h-zheng/.cache/huggingface:/root/.cache/huggingface \
  -v /mnt/weka/data/llm-d-models-pv:/mnt/weka/data/llm-d-models-pv:ro \
  -v /home/h-zheng/robin/llm-d/testing/results:/results \
  -w /home/h-zheng/robin/llm-d \
  -e RESULT_ROOT="/results/$(basename "${RESULT_ROOT}")" \
  -e HOST=127.0.0.1 \
  -e PORT=8000 \
  -e READY_CHECK_TIMEOUT_SEC=0 \
  amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_gpu:477-e3682ee \
  -lc 'testing/llm-d-internvl35-epd/scripts/bench-probe.sh 1agg 2.0 128' \
  2>&1 | tee "${RESULT_ROOT}/r2.0_1agg_docker.log"

kill "${PF_PID}" || true
NAMESPACE=shared-infra testing/llm-d-internvl35-epd/scripts/delete.sh \
  2>&1 | tee "${RESULT_ROOT}/cleanup_1agg.log"
```

Run 2E1PD:

```bash
cd /home/h-zheng/robin/llm-d
export PATH=/tmp/llmd-helm:$PATH
export NAMESPACE=shared-infra

# Reuse the RESULT_ROOT from the 1AGG block, or set a new one:
# RESULT_ROOT=/home/h-zheng/robin/llm-d/testing/results/manual_llmd_internvl35_$(date +%Y%m%d_%H%M%S)

NAMESPACE=shared-infra testing/llm-d-internvl35-epd/scripts/deploy-2e1pd.sh \
  2>&1 | tee "${RESULT_ROOT}/deploy_2e1pd.log"

kubectl get pods -n shared-infra -o wide | rg 'llmd-internvl35-2e1pd|NAME'
kubectl logs -n shared-infra deploy/llmd-internvl35-2e1pd-sglang-encode-0 -c modelserver | rg 'Using xpu_attn'
kubectl logs -n shared-infra deploy/llmd-internvl35-2e1pd-sglang-encode-1 -c modelserver | rg 'Using xpu_attn'

NAMESPACE=shared-infra LOCAL_PORT=8000 \
  testing/llm-d-internvl35-epd/scripts/port-forward.sh 2e1pd \
  >"${RESULT_ROOT}/port_forward_2e1pd.log" 2>&1 &
PF_PID=$!
sleep 3

docker run --rm --network host --entrypoint /bin/bash \
  -v /home/h-zheng/robin/llm-d:/home/h-zheng/robin/llm-d:ro \
  -v /home/h-zheng/.cache/huggingface:/root/.cache/huggingface \
  -v /mnt/weka/data/llm-d-models-pv:/mnt/weka/data/llm-d-models-pv:ro \
  -v /home/h-zheng/robin/llm-d/testing/results:/results \
  -w /home/h-zheng/robin/llm-d \
  -e RESULT_ROOT="/results/$(basename "${RESULT_ROOT}")" \
  -e HOST=127.0.0.1 \
  -e PORT=8000 \
  -e READY_CHECK_TIMEOUT_SEC=0 \
  amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_gpu:477-e3682ee \
  -lc 'testing/llm-d-internvl35-epd/scripts/bench-probe.sh 2e1pd 2.0 128' \
  2>&1 | tee "${RESULT_ROOT}/r2.0_2e1pd_docker.log"

kubectl logs -n shared-infra deploy/llmd-internvl35-2e1pd-sglang-decode -c modelserver \
  | rg 'Dispatching 8 mm items|No encoder URLs available|Health check evicted'

kill "${PF_PID}" || true
NAMESPACE=shared-infra testing/llm-d-internvl35-epd/scripts/delete.sh \
  2>&1 | tee "${RESULT_ROOT}/cleanup_2e1pd.log"
```

## Full Random Rate Sweep Reproduction

This loop deploys `1agg`, benchmarks, cleans up, then deploys `2e1pd`,
benchmarks, and cleans up for each rate.

```bash
cd /home/h-zheng/robin/llm-d
export PATH=/tmp/llmd-helm:$PATH
export NAMESPACE=shared-infra

RESULT_ROOT=/home/h-zheng/robin/llm-d/testing/results/manual_llmd_internvl35_matrix_$(date +%Y%m%d_%H%M%S)
mkdir -p "${RESULT_ROOT}"

cleanup_all() {
  kill "${PF_PID:-}" >/dev/null 2>&1 || true
  PATH=/tmp/llmd-helm:$PATH NAMESPACE=shared-infra \
    testing/llm-d-internvl35-epd/scripts/delete.sh >/dev/null 2>&1 || true
}
trap cleanup_all EXIT INT TERM

wait_clear() {
  for i in $(seq 1 90); do
    out=$(kubectl get pod,resourceclaim,resourceclaimtemplate -n shared-infra -o name 2>/dev/null | rg 'llmd-internvl35' || true)
    if [ -z "${out}" ]; then
      return 0
    fi
    sleep 5
  done
  echo "timed out waiting for cleanup" >&2
  return 1
}

run_case() {
  case_name="$1"
  rate="$2"
  deploy_script="$3"
  out_dir="${RESULT_ROOT}/r${rate}/${case_name}"
  mkdir -p "${out_dir}"

  PATH=/tmp/llmd-helm:$PATH NAMESPACE=shared-infra \
    "testing/llm-d-internvl35-epd/scripts/${deploy_script}" \
    2>&1 | tee "${out_dir}/deploy_${case_name}_r${rate}.log"

  kubectl get pods -n shared-infra -o wide \
    | rg "llmd-internvl35|NAME" \
    | tee "${out_dir}/pods_${case_name}_r${rate}.log"

  NAMESPACE=shared-infra LOCAL_PORT=8000 \
    testing/llm-d-internvl35-epd/scripts/port-forward.sh "${case_name}" \
    >"${out_dir}/port_forward_${case_name}_r${rate}.log" 2>&1 &
  PF_PID=$!
  sleep 3

  docker run --rm --network host --entrypoint /bin/bash \
    -v /home/h-zheng/robin/llm-d:/home/h-zheng/robin/llm-d:ro \
    -v /home/h-zheng/.cache/huggingface:/root/.cache/huggingface \
    -v /mnt/weka/data/llm-d-models-pv:/mnt/weka/data/llm-d-models-pv:ro \
    -v /home/h-zheng/robin/llm-d/testing/results:/results \
    -w /home/h-zheng/robin/llm-d \
    -e RESULT_ROOT="/results/$(basename "${RESULT_ROOT}")" \
    -e HOST=127.0.0.1 \
    -e PORT=8000 \
    -e READY_CHECK_TIMEOUT_SEC=0 \
    amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_gpu:477-e3682ee \
    -lc "testing/llm-d-internvl35-epd/scripts/bench-probe.sh ${case_name} ${rate} 128" \
    2>&1 | tee "${out_dir}/docker_${case_name}_r${rate}.log"

  kill "${PF_PID}" >/dev/null 2>&1 || true
  unset PF_PID

  PATH=/tmp/llmd-helm:$PATH NAMESPACE=shared-infra \
    testing/llm-d-internvl35-epd/scripts/delete.sh \
    2>&1 | tee "${out_dir}/cleanup_${case_name}_r${rate}.log"
  wait_clear
}

for rate in 0.2 0.4 0.6 0.8 1.0 1.2 1.4 1.6 1.8 2.0; do
  run_case 1agg "${rate}" deploy-1agg.sh
  run_case 2e1pd "${rate}" deploy-2e1pd.sh
done

find "${RESULT_ROOT}" -name 'bench_*.json' -print | sort | while read -r f; do
  jq -r --arg f "${f}" \
    '[$f, .completed, .request_rate, .request_throughput, .mean_ttft_ms, .mean_tpot_ms, .mean_e2e_latency_ms, .p99_e2e_latency_ms] | @tsv' \
    "${f}"
done
```

For a strict apples-to-apples comparison, require:

```text
.completed == 128
```

for every selected `bench_*.json`.

## Random Benchmark Results From Matrix Folder

The following table is extracted from:

```text
/home/h-zheng/robin/llm-d/testing/results/llm_d_internvl35_30b_a3b_k8s_matrix_20260708_185011_n128
```

Several benchmark processes exited normally but completed fewer than 128
requests. Those rows are kept here because this table is a faithful summary of
the requested artifact folder. Treat rows with `completed < 128` as partial
when making strict performance claims.

| rate | case | completed | req/s | mean TTFT ms | p99 TTFT ms | mean TPOT ms | p99 TPOT ms | mean E2E ms | p99 E2E ms |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.2 | `1agg` | 113 | 0.174 | 4358.17 | 11447.15 | 672.67 | 5424.79 | 7521.20 | 17682.21 |
| 0.2 | `2e1pd` | 119 | 0.185 | 851.48 | 1772.40 | 137.30 | 1347.12 | 1528.60 | 1937.93 |
| 0.4 | `1agg` | 98 | 0.294 | 5859.31 | 16932.40 | 1158.86 | 6562.00 | 11490.51 | 20825.56 |
| 0.4 | `2e1pd` | 128 | 0.396 | 774.73 | 1694.00 | 95.76 | 697.45 | 1334.86 | 1776.55 |
| 0.6 | `1agg` | 128 | 0.476 | 7582.96 | 17984.17 | 1669.89 | 10577.20 | 15400.59 | 22449.28 |
| 0.6 | `2e1pd` | 111 | 0.515 | 754.76 | 1872.15 | 119.33 | 1214.55 | 1343.61 | 1875.49 |
| 0.8 | `1agg` | 128 | 0.462 | 8261.17 | 20733.32 | 1813.63 | 15515.80 | 16641.43 | 26732.30 |
| 0.8 | `2e1pd` | 128 | 0.786 | 821.92 | 2311.38 | 190.62 | 1412.34 | 1675.11 | 2358.54 |
| 1.0 | `1agg` | 128 | 0.477 | 9547.19 | 18942.77 | 1415.88 | 9043.32 | 16356.77 | 26374.30 |
| 1.0 | `2e1pd` | 78 | 0.601 | 647.19 | 1619.41 | 135.29 | 783.10 | 1350.29 | 1758.29 |
| 1.2 | `1agg` | 128 | 0.469 | 8512.33 | 19754.44 | 1552.05 | 8157.17 | 16592.41 | 24709.82 |
| 1.2 | `2e1pd` | 128 | 1.171 | 799.37 | 2379.47 | 187.76 | 1578.14 | 1639.82 | 2540.22 |
| 1.4 | `1agg` | 128 | 0.473 | 7631.71 | 22785.20 | 1776.13 | 9748.86 | 16396.17 | 25753.73 |
| 1.4 | `2e1pd` | 128 | 1.361 | 811.16 | 2112.91 | 170.91 | 906.43 | 1642.36 | 2423.13 |
| 1.6 | `1agg` | 128 | 0.462 | 8249.01 | 21297.35 | 1810.75 | 14116.30 | 17060.86 | 27145.45 |
| 1.6 | `2e1pd` | 128 | 1.551 | 898.83 | 1956.08 | 143.56 | 884.95 | 1586.05 | 2223.59 |
| 1.8 | `1agg` | 128 | 0.465 | 7060.49 | 20168.87 | 1989.08 | 17098.95 | 16729.29 | 28679.95 |
| 1.8 | `2e1pd` | 128 | 1.738 | 868.08 | 2017.39 | 195.70 | 1397.93 | 1630.43 | 2392.83 |
| 2.0 | `1agg` | 128 | 0.472 | 7627.78 | 18984.45 | 1609.50 | 8357.70 | 16752.78 | 28744.89 |
| 2.0 | `2e1pd` | 128 | 1.920 | 944.27 | 2138.91 | 171.19 | 1453.19 | 1727.59 | 2667.97 |

The rate `2.0` point was later rerun with the same random workload and both
topologies completed 128 requests:

```text
/home/h-zheng/robin/llm-d/testing/results/llm_d_internvl35_30b_a3b_k8s_rerun_r2_random8img_20260709_085237
```

That rerun produced:

```text
1agg:  completed=128, req/s=0.46, mean E2E=16954.16 ms, mean TTFT=8030.23 ms
2e1pd: completed=128, req/s=1.92, mean E2E=1655.75 ms,  mean TTFT=832.00 ms
```

## MMMU Semantic Testing

The random benchmark is not a semantic correctness test. It uses random JPEGs,
random-token prompts, and short random outputs. Use MMMU to confirm that both
topologies can produce meaningful answers from real image/text inputs.

The MMMU audit script is:

```text
testing/llm-d-internvl35-epd/scripts/audit-mmmu-correctness.py
```

It:

```text
loads MMMU/MMMU from Hugging Face cache
sends one image per request through /v1/chat/completions
uses temperature=0.0
asks for "Final answer: <letter>"
saves image_00.png, request_for_review.json, response.json, summary.json
writes aggregate summary.json and summary.jsonl
```

### MMMU Clean Gate Used

The clean final semantic gate used two visually grounded `Computer_Science`
examples:

```text
config: Computer_Science
split: validation
ids: validation_Computer_Science_3,validation_Computer_Science_5
max_completion_tokens: 512
```

Result:

| case | MMMU id | answer | 1AGG predicted | 2E1PD predicted |
|---|---|---:|---:|---:|
| network-layer diagram | `validation_Computer_Science_3` | C | C | C |
| singly linked list diagram | `validation_Computer_Science_5` | A | A | A |

Artifact folder:

```text
/home/h-zheng/robin/llm-d/testing/results/llm_d_internvl35_30b_a3b_mmmu_semantic_cs_20260709_084013
```

Important note: `validation_Computer_Science_4` was explored but excluded from
the clean gate because 1AGG produced a long DFA analysis and did not emit a
parsable final answer within 512 tokens.

The earlier 3-case Math audit also passed by final letter for both topologies:

```text
/home/h-zheng/robin/llm-d/testing/results/llm_d_internvl35_30b_a3b_mmmu_semantic_20260709_082417_3case
```

Use the Computer Science two-case gate for repeatability because the outputs
were easier to judge semantically.

### MMMU Reproduction Commands

Deploy `1agg`, port-forward, run the audit, and clean up:

```bash
cd /home/h-zheng/robin/llm-d
export PATH=/tmp/llmd-helm:$PATH
export NAMESPACE=shared-infra

RESULT_ROOT=/home/h-zheng/robin/llm-d/testing/results/manual_mmmu_llmd_$(date +%Y%m%d_%H%M%S)
mkdir -p "${RESULT_ROOT}/1agg"

NAMESPACE=shared-infra testing/llm-d-internvl35-epd/scripts/deploy-1agg.sh \
  2>&1 | tee "${RESULT_ROOT}/1agg/deploy.log"

NAMESPACE=shared-infra LOCAL_PORT=8000 \
  testing/llm-d-internvl35-epd/scripts/port-forward.sh 1agg \
  >"${RESULT_ROOT}/1agg/port_forward.log" 2>&1 &
PF_PID=$!
sleep 3

docker run --rm --network host --entrypoint /bin/bash \
  -v /home/h-zheng/robin/llm-d:/home/h-zheng/robin/llm-d:ro \
  -v /home/h-zheng/.cache/huggingface:/root/.cache/huggingface \
  -v "${RESULT_ROOT}:/results" \
  -w /home/h-zheng/robin/llm-d \
  amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_gpu:477-e3682ee \
  -lc 'python3 testing/llm-d-internvl35-epd/scripts/audit-mmmu-correctness.py \
    --host 127.0.0.1 \
    --port 8000 \
    --output-dir /results/1agg/audit \
    --config Computer_Science \
    --split validation \
    --ids validation_Computer_Science_3,validation_Computer_Science_5 \
    --num-prompts 2 \
    --max-tokens 512 \
    --timeout 240' \
  2>&1 | tee "${RESULT_ROOT}/1agg/audit.log"

kill "${PF_PID}" || true
NAMESPACE=shared-infra testing/llm-d-internvl35-epd/scripts/delete.sh \
  2>&1 | tee "${RESULT_ROOT}/1agg/cleanup.log"
```

Deploy `2e1pd`, port-forward, run the same audit, and clean up:

```bash
mkdir -p "${RESULT_ROOT}/2e1pd"

NAMESPACE=shared-infra testing/llm-d-internvl35-epd/scripts/deploy-2e1pd.sh \
  2>&1 | tee "${RESULT_ROOT}/2e1pd/deploy.log"

kubectl get pods -n shared-infra -o wide | rg 'llmd-internvl35-2e1pd|NAME' \
  | tee "${RESULT_ROOT}/2e1pd/pods.log"
kubectl logs -n shared-infra deploy/llmd-internvl35-2e1pd-sglang-encode-0 -c modelserver | rg 'Using xpu_attn'
kubectl logs -n shared-infra deploy/llmd-internvl35-2e1pd-sglang-encode-1 -c modelserver | rg 'Using xpu_attn'

NAMESPACE=shared-infra LOCAL_PORT=8000 \
  testing/llm-d-internvl35-epd/scripts/port-forward.sh 2e1pd \
  >"${RESULT_ROOT}/2e1pd/port_forward.log" 2>&1 &
PF_PID=$!
sleep 3

docker run --rm --network host --entrypoint /bin/bash \
  -v /home/h-zheng/robin/llm-d:/home/h-zheng/robin/llm-d:ro \
  -v /home/h-zheng/.cache/huggingface:/root/.cache/huggingface \
  -v "${RESULT_ROOT}:/results" \
  -w /home/h-zheng/robin/llm-d \
  amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_gpu:477-e3682ee \
  -lc 'python3 testing/llm-d-internvl35-epd/scripts/audit-mmmu-correctness.py \
    --host 127.0.0.1 \
    --port 8000 \
    --output-dir /results/2e1pd/audit \
    --config Computer_Science \
    --split validation \
    --ids validation_Computer_Science_3,validation_Computer_Science_5 \
    --num-prompts 2 \
    --max-tokens 512 \
    --timeout 240' \
  2>&1 | tee "${RESULT_ROOT}/2e1pd/audit.log"

kubectl logs -n shared-infra deploy/llmd-internvl35-2e1pd-sglang-decode -c modelserver \
  | rg 'Dispatching 1 mm items|No encoder URLs available|Health check evicted'

kill "${PF_PID}" || true
NAMESPACE=shared-infra testing/llm-d-internvl35-epd/scripts/delete.sh \
  2>&1 | tee "${RESULT_ROOT}/2e1pd/cleanup.log"
```

Validate the MMMU result:

```bash
jq '{passed,total,records: [.records[] | {id, answer, predicted, passed, status_code, error}]}' \
  "${RESULT_ROOT}/1agg/audit/summary.json"
jq '{passed,total,records: [.records[] | {id, answer, predicted, passed, status_code, error}]}' \
  "${RESULT_ROOT}/2e1pd/audit/summary.json"
```

Expected result:

```text
1agg:  passed=2 total=2
2e1pd: passed=2 total=2
```

## Validation Checklist

Before a benchmark point:

```bash
kubectl get deploy,pod,svc,resourceclaim,resourceclaimtemplate -n shared-infra -o wide
ps -ef | rg 'kubectl port-forward|bench-probe|sglang.bench_serving|audit-mmmu'
docker ps --format 'table {{.ID}}\t{{.Status}}\t{{.Names}}\t{{.Command}}' | rg 'bench|audit|mmmu|NAMES'
```

After deploying `1agg`, verify:

```text
llmd-internvl35-1agg-sglang-decode is on sc09dell06-nvd
```

After deploying `2e1pd`, verify:

```text
llmd-internvl35-2e1pd-sglang-decode is on sc09dell06-nvd
llmd-internvl35-2e1pd-sglang-encode-0 is on sc09intel02-b60
llmd-internvl35-2e1pd-sglang-encode-1 is on sc09intel02-b60
wait-encoders init container is Completed
both encoder logs contain "Using xpu_attn as multimodal attention backend"
decode logs contain "Dispatching <N> mm items to 2 encoder(s)"
decode logs do not contain "No encoder URLs available" or "Health check evicted"
```

After cleanup:

```bash
kubectl get deploy,pod,svc,resourceclaim,resourceclaimtemplate -n shared-infra -o wide
ps -ef | rg 'kubectl port-forward|bench-probe|sglang.bench_serving|audit-mmmu'
docker ps --format 'table {{.ID}}\t{{.Status}}\t{{.Names}}\t{{.Command}}' | rg 'bench|audit|mmmu|NAMES'
```

The namespace check should show no `llmd-internvl35` resources.

## Known Issues And Recovery

1. Decode can start before encoders are healthy.

   Symptom:

   ```text
   Health check evicted 2 encoder(s) after 3 consecutive failures
   No encoder URLs available
   AttributeError: 'InternVLChatModel' object has no attribute 'vision_model'
   ```

   Recovery: ensure `wait-encoders` is rendered and redeploy `2e1pd`.

2. The llm-d EPP router can return 404 for `/v1/models`.

   Recovery: keep `READY_CHECK_TIMEOUT_SEC=0` for `bench-probe.sh`. Use
   Kubernetes rollout readiness and actual `/v1/chat/completions` requests as
   the effective readiness check.

3. Some matrix rows in the supplied artifact folder completed fewer than 128
   requests.

   Recovery: keep those artifacts for historical context, but rerun the same
   point if a strict matched comparison is required.

4. Random image benchmarks do not prove semantic correctness.

   Recovery: run the MMMU audit and inspect each case directory. The script
   saves the input image, reviewable request JSON, raw response, and parsed
   summary for each request.

## Cleanup Command

Use this after every test point:

```bash
PATH=/tmp/llmd-helm:$PATH NAMESPACE=shared-infra \
  testing/llm-d-internvl35-epd/scripts/delete.sh

for i in $(seq 1 90); do
  out=$(kubectl get pod,resourceclaim,resourceclaimtemplate -n shared-infra -o name 2>/dev/null | rg 'llmd-internvl35' || true)
  if [ -z "${out}" ]; then
    echo "llmd-internvl35 pods/resourceclaims cleared"
    break
  fi
  echo "${out}"
  sleep 5
done
```
