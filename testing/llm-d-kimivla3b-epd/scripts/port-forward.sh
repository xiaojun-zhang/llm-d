#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
local_port="${LOCAL_PORT:-8000}"
namespace="${NAMESPACE:-shared-infra}"

case "${case_name}" in
  1agg)
    svc="llmd-kimivla3b-1agg-epp"
    ;;
  2e1pd|pd)
    svc="llmd-kimivla3b-2e1pd-epp"
    ;;
  4e1pd)
    svc="llmd-kimivla3b-4e1pd-epp"
    ;;
  *)
    echo "usage: $0 {1agg|2e1pd|4e1pd}" >&2
    exit 2
    ;;
esac

echo "Forwarding localhost:${local_port} -> llm-d router service/${svc}:80 in ${namespace}"
kubectl port-forward -n "${namespace}" "service/${svc}" "${local_port}:80"
