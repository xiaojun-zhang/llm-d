#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${ROOT_DIR}/../.." && pwd)"
NAMESPACE="${NAMESPACE:-shared-infra}"
RELEASE_NAME="${RELEASE_NAME:-llmd-internvl35-1agg}"
MODEL_KUSTOMIZE="${ROOT_DIR}/modelserver/1agg/sglang"
ROUTER_CREATE_INFERENCEPOOL="${ROUTER_CREATE_INFERENCEPOOL:-false}"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to deploy the llm-d router" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${REPO_ROOT}/guides/env.sh"

echo "Deploying 1AGG in namespace ${NAMESPACE}"
echo "H200 card: sc09dell06-nvd GPU 7, UUID GPU-5fd91b51-6253-0459-27bd-de55bb3e8ae6"
echo "This will create pods and ResourceClaims; run only after cards are reserved."

helm upgrade --install "${RELEASE_NAME}" "${ROUTER_STANDALONE_CHART}" \
  -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
  -f "${ROOT_DIR}/router/1agg.values.yaml" \
  --set "router.inferencePool.create=${ROUTER_CREATE_INFERENCEPOOL}" \
  -n "${NAMESPACE}" --version "${ROUTER_CHART_VERSION}"

kubectl apply -n "${NAMESPACE}" -k "${MODEL_KUSTOMIZE}"
kubectl rollout status deployment/llmd-internvl35-1agg-sglang-decode \
  -n "${NAMESPACE}" --timeout=45m
