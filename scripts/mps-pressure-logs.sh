#!/usr/bin/env bash
set -euo pipefail

# Usage: mps-pressure-logs.sh [NAMESPACE] [--follow]
NAMESPACE=${1:-default}
FOLLOW_FLAG=${2:---follow}

echo "Streaming logs for pods with label test=mps-pressure in namespace $NAMESPACE"

# kubectl supports selecting by label; -c selects the container
kubectl logs -l test=mps-pressure -n "$NAMESPACE" -c cuda-app $FOLLOW_FLAG
