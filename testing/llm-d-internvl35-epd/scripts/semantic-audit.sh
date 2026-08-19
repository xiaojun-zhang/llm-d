#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${ROOT_DIR}/../.." && pwd)"

case_name="${1:-}"
host="${HOST:-127.0.0.1}"
port="${PORT:-8000}"
timeout="${AUDIT_TIMEOUT:-180}"
max_tokens="${AUDIT_MAX_TOKENS:-64}"
timestamp="$(date +%Y%m%d_%H%M%S)"

if [[ "${case_name}" != "1agg" && "${case_name}" != "2e1pd" ]]; then
  echo "usage: $0 {1agg|2e1pd}" >&2
  exit 2
fi

model="${AUDIT_MODEL:-/mnt/weka/data/llm-d-models-pv/hub/models--OpenGVLab--InternVL3_5-30B-A3B/snapshots/main}"
result_root="${RESULT_ROOT:-${REPO_ROOT}/testing/results/llm_d_internvl35_30b_a3b_semantic_audit_${timestamp}}"
out_dir="${result_root}/${case_name}/audit"
mkdir -p "${out_dir}"

cmd=(
  python3 "${SCRIPT_DIR}/audit-image-correctness.py"
  --host "${host}"
  --port "${port}"
  --model "${model}"
  --output-dir "${out_dir}"
  --timeout "${timeout}"
  --max-tokens "${max_tokens}"
)

if [[ -n "${AUDIT_DOCKER_IMAGE:-}" ]]; then
  container_out="/results/${case_name}/audit"
  cmd=(
    docker run --rm --network host
    -v "${REPO_ROOT}:${REPO_ROOT}:ro"
    -v "${result_root}:/results"
    -w "${REPO_ROOT}"
    "${AUDIT_DOCKER_IMAGE}"
    python3 "${SCRIPT_DIR}/audit-image-correctness.py"
    --host "${host}"
    --port "${port}"
    --model "${model}"
    --output-dir "${container_out}"
    --timeout "${timeout}"
    --max-tokens "${max_tokens}"
  )
fi

"${cmd[@]}" 2>&1 | tee "${result_root}/${case_name}/audit.log"
echo "wrote ${out_dir}"
