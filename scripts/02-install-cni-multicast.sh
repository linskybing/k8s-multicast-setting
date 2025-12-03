#!/bin/bash
set -e

echo "=== Installing Multus CNI ==="
# Install Multus (Thick plugin is recommended for newer k8s)
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml

echo "Waiting for Multus pods to be ready..."
kubectl wait --for=condition=ready pod -l app=multus -n kube-system --timeout=300s

echo "=== Configuring Macvlan for Multicast ==="

# Check if manifest exists, if not create a template
if [ ! -f ../manifests/cni/macvlan-conf.yaml ]; then
    echo "Creating default macvlan-conf.yaml template..."
    mkdir -p ../manifests/cni
    cat <<EOF > ../manifests/cni/macvlan-conf.yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-conf
  namespace: default
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.1.0/24",
        "rangeStart": "192.168.1.200",
        "rangeEnd": "192.168.1.210",
        "routes": [
          { "dst": "0.0.0.0/0" }
        ],
        "gateway": "192.168.1.1"
      }
    }'
EOF
    echo "WARNING: Created ../manifests/cni/macvlan-conf.yaml with default values."
    echo "Please edit it to match your physical interface (master) and subnet."
fi

# Create macvlan network configuration
kubectl apply -f ../manifests/cni/macvlan-conf.yaml

# Verify macvlan configuration
echo "Verifying NetworkAttachmentDefinitions..."
kubectl get network-attachment-definitions -A