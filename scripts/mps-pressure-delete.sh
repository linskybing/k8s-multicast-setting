#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${1:-default}
MANIFEST=${2:-"../manifests/test/mps-pressure-240-job.yaml"}

echo "Deleting resources from $MANIFEST in namespace $NAMESPACE"
kubectl delete -f "$MANIFEST" -n "$NAMESPACE" --ignore-not-found

echo "Also deleting any leftover pods with label test=mps-pressure"
kubectl delete pods -l test=mps-pressure -n "$NAMESPACE" --ignore-not-found

echo "Also deleting any leftover jobs named mps-pressure"
kubectl delete job mps-pressure -n "$NAMESPACE" --ignore-not-found

echo "Done."
