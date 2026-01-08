#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${1:-default}
MANIFEST=${2:-"../manifests/test/mps-pressure-240-job.yaml"}

echo "Applying $MANIFEST to namespace $NAMESPACE"
kubectl apply -f "$MANIFEST" -n "$NAMESPACE"

echo "Job status (mps-pressure):"
kubectl get job mps-pressure -n "$NAMESPACE" -o wide || true

echo "Pods (wide):"
kubectl get pods -l test=mps-pressure -n "$NAMESPACE" -o wide

echo "Done. Use scripts/mps-pressure-logs.sh to stream logs, or scripts/mps-pressure-delete.sh to remove." 
