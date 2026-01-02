#!/bin/bash
set -euo pipefail

# Simple runner for MPS validation manifests.
# Usage: sudo ./test-mps.sh [namespace]
# Default namespace: mps-test

NS=${1:-mps-test}
ROOT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)

echo "[1/4] Ensuring namespace $NS exists..."
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

echo "[2/4] Applying MPS test manifests..."
kubectl apply -n "$NS" -f "$ROOT_DIR/manifests/test/mps-memory-test.yaml"
kubectl apply -n "$NS" -f "$ROOT_DIR/manifests/test/mps-thread-test.yaml"
kubectl apply -n "$NS" -f "$ROOT_DIR/manifests/test/mps-4gpu-test.yaml"

echo "[3/4] Waiting for Pods to complete..."
kubectl wait -n "$NS" --for=condition=Completed pod/mps-test-success --timeout=600s || true
kubectl wait -n "$NS" --for=condition=Completed pod/mps-test-fail --timeout=600s || true
kubectl wait -n "$NS" --for=condition=Completed pod/mps-baseline --timeout=600s || true
kubectl wait -n "$NS" --for=condition=Completed pod/mps-limited --timeout=600s || true

echo "[3b/4] Waiting for Jobs to complete..."
kubectl wait -n "$NS" --for=condition=Complete job/mps-benchmark-baseline-4gpu --timeout=1200s || true
kubectl wait -n "$NS" --for=condition=Complete job/mps-benchmark-limited-4gpu --timeout=1200s || true

echo "[4/4] Collecting logs (stdout only)..."
kubectl logs -n "$NS" pod/mps-test-success || true
kubectl logs -n "$NS" pod/mps-test-fail || true
kubectl logs -n "$NS" pod/mps-baseline || true
kubectl logs -n "$NS" pod/mps-limited || true

for pod in $(kubectl get pods -n "$NS" -l app=mps-baseline-4gpu -o name 2>/dev/null); do
  kubectl logs -n "$NS" "$pod" || true
done
for pod in $(kubectl get pods -n "$NS" -l app=mps-limited-4gpu -o name 2>/dev/null); do
  kubectl logs -n "$NS" "$pod" || true
done

echo "Done. Review logs above for timing and CUDA allocator results."