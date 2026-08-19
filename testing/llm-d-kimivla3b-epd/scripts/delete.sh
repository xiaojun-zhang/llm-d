#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${NAMESPACE:-shared-infra}"

kubectl delete -n "${NAMESPACE}" -k "${ROOT_DIR}/modelserver/2e1pd/sglang" --ignore-not-found
kubectl delete -n "${NAMESPACE}" -k "${ROOT_DIR}/modelserver/4e1pd/sglang" --ignore-not-found
kubectl delete -n "${NAMESPACE}" -k "${ROOT_DIR}/modelserver/1agg/sglang" --ignore-not-found

if command -v helm >/dev/null 2>&1; then
  helm uninstall llmd-kimivla3b-4e1pd -n "${NAMESPACE}" || true
  helm uninstall llmd-kimivla3b-2e1pd -n "${NAMESPACE}" || true
  helm uninstall llmd-kimivla3b-1agg -n "${NAMESPACE}" || true
else
  echo "helm not found; skipped router release uninstall" >&2
fi
