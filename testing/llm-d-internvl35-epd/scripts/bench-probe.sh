#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${ROOT_DIR}/../.." && pwd)"

case_name="${1:-}"
rate="${2:-1.0}"
num_prompts="${3:-32}"
host="${HOST:-127.0.0.1}"
port="${PORT:-8000}"
ready_check_timeout_sec="${READY_CHECK_TIMEOUT_SEC:-0}"
timestamp="$(date +%Y%m%d_%H%M%S)"

if [[ "${case_name}" != "1agg" && "${case_name}" != "2e1pd" ]]; then
  echo "usage: $0 {1agg|2e1pd} [rate] [num_prompts]" >&2
  exit 2
fi

model="/mnt/weka/data/llm-d-models-pv/hub/models--OpenGVLab--InternVL3_5-30B-A3B/snapshots/main"
result_root="${RESULT_ROOT:-${REPO_ROOT}/testing/results/llm_d_internvl35_30b_a3b_k8s_probe_${timestamp}}"
out_dir="${result_root}/r${rate}/${case_name}"
mkdir -p "${out_dir}"

if [[ "${USE_BENCH_PATCHES:-1}" != "0" ]]; then
  export BENCH_PYTHONPATH="${BENCH_PYTHONPATH:-${ROOT_DIR}/bench_patches}"
  export PYTHONPATH="${BENCH_PYTHONPATH}${PYTHONPATH:+:${PYTHONPATH}}"
fi

python3 -m sglang.bench_serving \
  --model "${model}" \
  --backend sglang-oai-chat \
  --host "${host}" \
  --port "${port}" \
  --ready-check-timeout-sec "${ready_check_timeout_sec}" \
  --dataset-name image \
  --num-prompts "${num_prompts}" \
  --random-input-len 128 \
  --random-output-len 16 \
  --image-count 8 \
  --image-resolution 1080p \
  --request-rate "${rate}" \
  --apply-chat-template \
  --seed 0 \
  --disable-tqdm \
  --output-file "${out_dir}/bench_${case_name}_r${rate}.json" \
  --max-concurrency 8 \
  2>&1 | tee "${out_dir}/result_${case_name}_r${rate}.txt"

echo "wrote ${out_dir}"
