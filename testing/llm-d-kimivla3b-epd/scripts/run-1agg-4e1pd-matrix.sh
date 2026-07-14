#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${ROOT_DIR}/../.." && pwd)"
RESULTS_DIR="${REPO_ROOT}/testing/results"
NAMESPACE="${NAMESPACE:-shared-infra}"
BENCH_IMAGE="${BENCH_IMAGE:-amr-registry.caas.intel.com/taas/scalable-deploy-intel/main_dockerfile.dynamo_gpu:477-e3682ee}"
NUM_PROMPTS="${NUM_PROMPTS:-128}"
RATES="${RATES:-0.2 0.4 0.6 0.8 1.0 1.2 1.4 1.6 1.8 2.0}"
IMAGE_COUNT="${IMAGE_COUNT:-4}"
IMAGE_RESOLUTION="${IMAGE_RESOLUTION:-1080p}"
RANDOM_INPUT_LEN="${RANDOM_INPUT_LEN:-128}"
RANDOM_OUTPUT_LEN="${RANDOM_OUTPUT_LEN:-16}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-8}"
LOCAL_PORT="${LOCAL_PORT:-8000}"
RUN_1AGG_SMOKE="${RUN_1AGG_SMOKE:-true}"
timestamp="$(date +%Y%m%d_%H%M%S)"
RESULT_ROOT="${RESULT_ROOT:-${RESULTS_DIR}/llm_d_kimivla3b_1agg_4e1pd_4img_matrix_super21_intel02_${timestamp}_n${NUM_PROMPTS}}"
PF_PID=""

if [[ "${RESULT_ROOT}" != "${RESULTS_DIR}/"* ]]; then
  echo "RESULT_ROOT must be below ${RESULTS_DIR}" >&2
  exit 2
fi

mkdir -p "${RESULT_ROOT}/manifests"

cleanup_all() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" >/dev/null 2>&1 || true
    PF_PID=""
  fi
  PATH="/tmp/llmd-helm:${PATH}" NAMESPACE="${NAMESPACE}" \
    "${SCRIPT_DIR}/delete.sh" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT INT TERM

wait_clear() {
  local remaining
  for _ in $(seq 1 120); do
    remaining="$(
      kubectl get pod,resourceclaim,resourceclaimtemplate -n "${NAMESPACE}" -o name 2>/dev/null \
        | grep 'llmd-kimivla3b' || true
    )"
    if [[ -z "${remaining}" ]]; then
      return 0
    fi
    sleep 5
  done
  echo "timed out waiting for Kimi-VL resources to terminate" >&2
  return 1
}

start_port_forward() {
  local case_name="$1"
  local log_file="$2"

  NAMESPACE="${NAMESPACE}" LOCAL_PORT="${LOCAL_PORT}" \
    "${SCRIPT_DIR}/port-forward.sh" "${case_name}" >"${log_file}" 2>&1 &
  PF_PID=$!

  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${LOCAL_PORT}/v1/models" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "${PF_PID}" >/dev/null 2>&1; then
      cat "${log_file}" >&2
      return 1
    fi
    sleep 2
  done
  echo "router did not become reachable through port-forward" >&2
  return 1
}

stop_port_forward() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" >/dev/null 2>&1 || true
    PF_PID=""
  fi
}

capture_cluster_state() {
  local case_name="$1"
  local out_dir="$2"

  kubectl get pods -n "${NAMESPACE}" -o wide >"${out_dir}/pods.txt"
  kubectl get deployment,service,resourceclaim,resourceclaimtemplate \
    -n "${NAMESPACE}" -o wide >"${out_dir}/resources.txt"
  kubectl get resourceclaim -n "${NAMESPACE}" -o yaml >"${out_dir}/resourceclaims.yaml"

  kubectl logs -n "${NAMESPACE}" \
    "deployment/llmd-kimivla3b-${case_name}-sglang-decode" \
    -c modelserver >"${out_dir}/decode.log" 2>&1 || true

  if [[ "${case_name}" == "4e1pd" ]]; then
    for encoder in 0 1 2 3; do
      kubectl exec -n "${NAMESPACE}" \
        "deployment/llmd-kimivla3b-4e1pd-sglang-encode-${encoder}" \
        -c modelserver -- \
        sh -lc "tr '\\0' ' ' </proc/1/cmdline" \
        >"${out_dir}/encode-${encoder}-cmdline.txt" 2>&1 || true
      kubectl logs -n "${NAMESPACE}" \
        "deployment/llmd-kimivla3b-4e1pd-sglang-encode-${encoder}" \
        -c modelserver >"${out_dir}/encode-${encoder}.log" 2>&1 || true
    done
  fi
}

run_benchmark() {
  local result_base="$1"
  local case_name="$2"
  local rate="$3"
  local prompts="$4"
  local out_dir="$5"
  local result_relative="${result_base#"${RESULTS_DIR}/"}"

  docker run --rm --network host --entrypoint /bin/bash \
    -v "${REPO_ROOT}:${REPO_ROOT}:ro" \
    -v /home/h-zheng/.cache/huggingface:/root/.cache/huggingface \
    -v /mnt/weka/data/llm-d-models-pv:/mnt/weka/data/llm-d-models-pv:ro \
    -v "${RESULTS_DIR}:/results" \
    -w "${REPO_ROOT}" \
    -e RESULT_ROOT="/results/${result_relative}" \
    -e HOST=127.0.0.1 \
    -e PORT="${LOCAL_PORT}" \
    -e READY_CHECK_TIMEOUT_SEC=0 \
    -e IMAGE_COUNT="${IMAGE_COUNT}" \
    -e IMAGE_RESOLUTION="${IMAGE_RESOLUTION}" \
    -e RANDOM_INPUT_LEN="${RANDOM_INPUT_LEN}" \
    -e RANDOM_OUTPUT_LEN="${RANDOM_OUTPUT_LEN}" \
    -e MAX_CONCURRENCY="${MAX_CONCURRENCY}" \
    "${BENCH_IMAGE}" \
    -lc "${ROOT_DIR#${REPO_ROOT}/}/scripts/bench-probe.sh ${case_name} ${rate} ${prompts}" \
    2>&1 | tee "${out_dir}/docker_bench_${case_name}_r${rate}.log"
}

run_case() {
  local result_base="$1"
  local case_name="$2"
  local rate="$3"
  local prompts="$4"
  local phase="$5"
  local deploy_script
  local out_dir="${result_base}/r${rate}/${case_name}"
  local bench_json="${out_dir}/bench_${case_name}_r${rate}.json"

  case "${case_name}" in
    1agg) deploy_script="deploy-1agg.sh" ;;
    4e1pd) deploy_script="deploy-4e1pd.sh" ;;
    *) echo "unsupported case: ${case_name}" >&2; return 2 ;;
  esac

  mkdir -p "${out_dir}"
  cleanup_all
  wait_clear

  echo "[$(date --iso-8601=seconds)] ${phase}: deploying ${case_name} at rate ${rate}"
  PATH="/tmp/llmd-helm:${PATH}" NAMESPACE="${NAMESPACE}" \
    "${SCRIPT_DIR}/${deploy_script}" \
    2>&1 | tee "${out_dir}/deploy_${case_name}_r${rate}.log"

  capture_cluster_state "${case_name}" "${out_dir}"
  start_port_forward "${case_name}" "${out_dir}/port_forward.log"
  run_benchmark "${result_base}" "${case_name}" "${rate}" "${prompts}" "${out_dir}"
  stop_port_forward
  capture_cluster_state "${case_name}" "${out_dir}"

  jq -e --argjson expected "${prompts}" \
    '.completed == $expected' "${bench_json}" >/dev/null

  if [[ "${case_name}" == "4e1pd" ]]; then
    for encoder in 0 1 2 3; do
      grep -q -- "--mm-attention-backend=xpu_attn" \
        "${out_dir}/encode-${encoder}-cmdline.txt"
    done
  fi

  PATH="/tmp/llmd-helm:${PATH}" NAMESPACE="${NAMESPACE}" \
    "${SCRIPT_DIR}/delete.sh" \
    2>&1 | tee "${out_dir}/cleanup_${case_name}_r${rate}.log"
  wait_clear
  echo "[$(date --iso-8601=seconds)] ${phase}: completed ${case_name} at rate ${rate}"
}

cat >"${RESULT_ROOT}/configuration.txt" <<EOF
model=moonshotai/Kimi-VL-A3B-Instruct
namespace=${NAMESPACE}
gpu_node=sc09super21-h200
gpu_card=7
gpu_uuid=GPU-5566797f-f7a9-dac4-32c7-f2f0ea80a1f7
xpu_node=sc09intel02-b60
xpu_cards=0,1,2,3
xpu_pci=0000:18:00.0,0000:1c:00.0,0000:54:00.0,0000:58:00.0
num_prompts=${NUM_PROMPTS}
rates=${RATES}
image_count=${IMAGE_COUNT}
image_resolution=${IMAGE_RESOLUTION}
random_input_len=${RANDOM_INPUT_LEN}
random_output_len=${RANDOM_OUTPUT_LEN}
max_concurrency=${MAX_CONCURRENCY}
run_1agg_smoke=${RUN_1AGG_SMOKE}
bench_image=${BENCH_IMAGE}
EOF

kubectl kustomize "${ROOT_DIR}/modelserver/1agg/sglang" \
  >"${RESULT_ROOT}/manifests/1agg.yaml"
kubectl kustomize "${ROOT_DIR}/modelserver/4e1pd/sglang" \
  >"${RESULT_ROOT}/manifests/4e1pd.yaml"

cleanup_all
wait_clear

echo "Running pre-matrix smoke tests"
if [[ "${RUN_1AGG_SMOKE}" == "true" ]]; then
  run_case "${RESULT_ROOT}/smoke" 1agg 1.0 1 smoke
fi
run_case "${RESULT_ROOT}/smoke" 4e1pd 1.0 1 smoke

echo "Smoke tests passed; starting full matrix"
for rate in ${RATES}; do
  run_case "${RESULT_ROOT}" 1agg "${rate}" "${NUM_PROMPTS}" matrix
  run_case "${RESULT_ROOT}" 4e1pd "${rate}" "${NUM_PROMPTS}" matrix
done

find "${RESULT_ROOT}" -path '*/r*/*/bench_*.json' -not -path '*/smoke/*' -print0 \
  | sort -z \
  | xargs -0 -r jq -r \
      '[input_filename, .completed, .request_rate, .request_throughput, .mean_ttft_ms, .mean_tpot_ms, .mean_e2e_latency_ms, .p99_e2e_latency_ms] | @tsv' \
  >"${RESULT_ROOT}/summary.tsv"

kubectl get pod,resourceclaim,resourceclaimtemplate -n "${NAMESPACE}" -o wide \
  >"${RESULT_ROOT}/final_resources.txt" 2>&1 || true

echo "Completed matrix: ${RESULT_ROOT}"
