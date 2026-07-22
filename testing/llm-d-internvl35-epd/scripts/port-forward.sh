#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
local_port="${LOCAL_PORT:-8000}"
namespace="${NAMESPACE:-shared-infra}"

case "${case_name}" in
  1agg)
    svc="llmd-internvl35-1agg-epp"
    ;;
  2e1pd|pd)
    svc="llmd-internvl35-2e1pd-epp"
    ;;
  *)
    echo "usage: $0 {1agg|2e1pd}" >&2
    exit 2
    ;;
esac

echo "Forwarding localhost:${local_port} -> llm-d router service/${svc}:80 in ${namespace}"
kubectl port-forward -n "${namespace}" "service/${svc}" "${local_port}:80"
