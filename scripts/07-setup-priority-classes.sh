#!/bin/bash
set -e

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "=== Setting up Kubernetes Priority Classes ==="
kubectl apply -f "$SCRIPT_DIR/../manifests/priority-classes.yaml"

echo "Priority Classes 'high-priority' and 'low-priority' created."
