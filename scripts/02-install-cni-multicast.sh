#!/bin/bash
set -e

# ================= Configuration =================
MULTUS_VERSION="v4.0.2"
WHEREABOUTS_VERSION="v0.6.3"

# Resource Limits
MULTUS_MEM_REQUEST="256Mi"
MULTUS_MEM_LIMIT="512Mi"

# Macvlan Configuration
MASTER_IF=${MASTER_IF:-eth0}
# [Network] Ensure this subnet matches your physical network
SUBNET=${SUBNET:-192.168.1.0/24} 
GATEWAY=${GATEWAY:-192.168.1.1}
# Range to be managed by K8s (Must exclude Gateway and Static IPs of hosts)
RANGE=${RANGE:-192.168.1.200-192.168.1.250/24}

NAD_NAME=${NAD_NAME:-macvlan-conf}
NAD_NAMESPACE=${NAD_NAMESPACE:-default}
MANIFEST_PATH=${MANIFEST_PATH:-"../manifests/cni/${NAD_NAME}.yaml"}
# =================================================

echo "=== 1. Installing Multus CNI (Thick Plugin - v${MULTUS_VERSION}) ==="
MULTUS_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml"

echo "Downloading manifest from: $MULTUS_URL"
curl -sL "$MULTUS_URL" -o multus-temp.yaml

echo "Patching resource limits before apply..."
# We patch the YAML locally to avoid double-restart of the DaemonSet
sed -i "s/memory: .*/memory: $MULTUS_MEM_LIMIT/g" multus-temp.yaml
# (Simple sed assumes standard formatting; for complex patching, yq is better, but sed works for standard manifest)

kubectl apply -f multus-temp.yaml
rm multus-temp.yaml

echo "Waiting for Multus to be ready..."
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=300s

echo "=== 2. Installing Whereabouts IPAM (${WHEREABOUTS_VERSION}) ==="
# [CRITICAL] Whereabouts ensures Node A and Node B don't issue the same IP.
# It uses Etcd (via CRDs) to track IP allocations cluster-wide.
WHEREABOUTS_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/${WHEREABOUTS_VERSION}/doc/crds/daemonset-install.yaml"
kubectl apply -f "$WHEREABOUTS_URL"

echo "Waiting for Whereabouts to be ready..."
kubectl -n kube-system rollout status daemonset/whereabouts --timeout=300s

echo "=== 3. Configuring Macvlan + Whereabouts ==="

mkdir -p "$(dirname "$MANIFEST_PATH")"

# Generate NAD with Whereabouts IPAM
cat <<EOF > "$MANIFEST_PATH"
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: $NAD_NAME
  namespace: $NAD_NAMESPACE
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "$MASTER_IF",
      "mode": "bridge",
      "ipam": {
        "type": "whereabouts",
        "range": "$RANGE",
        "gateway": "$GATEWAY",
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    }'
EOF

echo "Created Manifest at: $MANIFEST_PATH"
kubectl apply -f "$MANIFEST_PATH"

echo "=== Verification ==="
echo "1. Network Attachment Definitions:"
kubectl get network-attachment-definitions -A
echo "2. Checking IPAM status (Should show Whereabouts pods):"
kubectl get pods -n kube-system -l app=whereabouts

echo "-------------------------------------------------------"
echo "Setup Complete. Uses 'Whereabouts' for safe cluster-wide IP allocation."