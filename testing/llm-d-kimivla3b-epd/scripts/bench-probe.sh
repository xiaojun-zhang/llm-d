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
random_input_len="${RANDOM_INPUT_LEN:-128}"
random_output_len="${RANDOM_OUTPUT_LEN:-16}"
image_count="${IMAGE_COUNT:-8}"
image_resolution="${IMAGE_RESOLUTION:-1080p}"
max_concurrency="${MAX_CONCURRENCY:-8}"
timestamp="$(date +%Y%m%d_%H%M%S)"

if [[ "${case_name}" != "1agg" && "${case_name}" != "2e1pd" && "${case_name}" != "4e1pd" ]]; then
  echo "usage: $0 {1agg|2e1pd|4e1pd} [rate] [num_prompts]" >&2
  exit 2
fi

model="/mnt/weka/data/llm-d-models-pv/hub/models--moonshotai--Kimi-VL-A3B-Instruct/snapshots/main"
served_model_name="moonshotai/Kimi-VL-A3B-Instruct"
result_root="${RESULT_ROOT:-${REPO_ROOT}/testing/results/llm_d_kimivla3b_k8s_probe_${timestamp}}"
out_dir="${result_root}/r${rate}/${case_name}"
mkdir -p "${out_dir}"

python3 -m sglang.bench_serving \
  --model "${model}" \
  --served-model-name "${served_model_name}" \
  --backend sglang-oai-chat \
  --host "${host}" \
  --port "${port}" \
  --ready-check-timeout-sec "${ready_check_timeout_sec}" \
  --dataset-name image \
  --num-prompts "${num_prompts}" \
  --random-input-len "${random_input_len}" \
  --random-output-len "${random_output_len}" \
  --image-count "${image_count}" \
  --image-resolution "${image_resolution}" \
  --request-rate "${rate}" \
  --apply-chat-template \
  --seed 0 \
  --disable-tqdm \
  --output-file "${out_dir}/bench_${case_name}_r${rate}.json" \
  --max-concurrency "${max_concurrency}" \
  2>&1 | tee "${out_dir}/result_${case_name}_r${rate}.txt"

echo "wrote ${out_dir}"
