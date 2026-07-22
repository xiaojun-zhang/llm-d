#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${ROOT_DIR}/../.." && pwd)"
NAMESPACE="${NAMESPACE:-shared-infra}"
ROUTER_CREATE_INFERENCEPOOL="${ROUTER_CREATE_INFERENCEPOOL:-false}"

kubectl kustomize "${ROOT_DIR}/modelserver/1agg/sglang" >/dev/null
kubectl kustomize "${ROOT_DIR}/modelserver/2e1pd/sglang" >/dev/null
kubectl kustomize "${ROOT_DIR}/modelserver/4e1pd/sglang" >/dev/null

kubectl apply --dry-run=client --validate=false -n "${NAMESPACE}" \
  -k "${ROOT_DIR}/modelserver/1agg/sglang" >/dev/null
kubectl apply --dry-run=client --validate=false -n "${NAMESPACE}" \
  -k "${ROOT_DIR}/modelserver/2e1pd/sglang" >/dev/null
kubectl apply --dry-run=client --validate=false -n "${NAMESPACE}" \
  -k "${ROOT_DIR}/modelserver/4e1pd/sglang" >/dev/null

if command -v helm >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/guides/env.sh"
  helm template llmd-kimivla3b-1agg "${ROUTER_STANDALONE_CHART}" \
    -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
    -f "${ROOT_DIR}/router/1agg.values.yaml" \
    --set "router.inferencePool.create=${ROUTER_CREATE_INFERENCEPOOL}" \
    -n "${NAMESPACE}" --version "${ROUTER_CHART_VERSION}" >/dev/null
  helm template llmd-kimivla3b-2e1pd "${ROUTER_STANDALONE_CHART}" \
    -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
    -f "${ROOT_DIR}/router/2e1pd.values.yaml" \
    --set "router.inferencePool.create=${ROUTER_CREATE_INFERENCEPOOL}" \
    -n "${NAMESPACE}" --version "${ROUTER_CHART_VERSION}" >/dev/null
  helm template llmd-kimivla3b-4e1pd "${ROUTER_STANDALONE_CHART}" \
    -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
    -f "${ROOT_DIR}/router/4e1pd.values.yaml" \
    --set "router.inferencePool.create=${ROUTER_CREATE_INFERENCEPOOL}" \
    -n "${NAMESPACE}" --version "${ROUTER_CHART_VERSION}" >/dev/null
else
  echo "helm not found; skipped router chart template validation" >&2
fi

echo "client-side llm-d router/modelserver validation passed"
