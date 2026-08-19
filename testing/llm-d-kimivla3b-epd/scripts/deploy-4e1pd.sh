#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${ROOT_DIR}/../.." && pwd)"
NAMESPACE="${NAMESPACE:-shared-infra}"
RELEASE_NAME="${RELEASE_NAME:-llmd-kimivla3b-4e1pd}"
MODEL_KUSTOMIZE="${ROOT_DIR}/modelserver/4e1pd/sglang"
ROUTER_CREATE_INFERENCEPOOL="${ROUTER_CREATE_INFERENCEPOOL:-false}"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to deploy the llm-d router" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${REPO_ROOT}/guides/env.sh"

echo "Deploying 4E1PD in namespace ${NAMESPACE}"
echo "H200 PD card: sc09super21-h200 GPU 7, UUID GPU-5566797f-f7a9-dac4-32c7-f2f0ea80a1f7"
echo "B60 encoder cards: sc09intel02-b60 XPU 0 PCI 0000:18:00.0, XPU 1 PCI 0000:1c:00.0, XPU 2 PCI 0000:54:00.0, XPU 3 PCI 0000:58:00.0"
echo "This will create pods and ResourceClaims; run only after cards are reserved."

helm upgrade --install "${RELEASE_NAME}" "${ROUTER_STANDALONE_CHART}" \
  -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
  -f "${ROOT_DIR}/router/4e1pd.values.yaml" \
  --set "router.inferencePool.create=${ROUTER_CREATE_INFERENCEPOOL}" \
  -n "${NAMESPACE}" --version "${ROUTER_CHART_VERSION}"

kubectl apply -n "${NAMESPACE}" -k "${MODEL_KUSTOMIZE}"
kubectl rollout status deployment/llmd-kimivla3b-4e1pd-sglang-encode-0 \
  -n "${NAMESPACE}" --timeout=45m
kubectl rollout status deployment/llmd-kimivla3b-4e1pd-sglang-encode-1 \
  -n "${NAMESPACE}" --timeout=45m
kubectl rollout status deployment/llmd-kimivla3b-4e1pd-sglang-encode-2 \
  -n "${NAMESPACE}" --timeout=45m
kubectl rollout status deployment/llmd-kimivla3b-4e1pd-sglang-encode-3 \
  -n "${NAMESPACE}" --timeout=45m
kubectl rollout status deployment/llmd-kimivla3b-4e1pd-sglang-decode \
  -n "${NAMESPACE}" --timeout=45m
