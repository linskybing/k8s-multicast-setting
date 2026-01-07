#!/bin/bash
set -e
# ==============================================================================
# NVIDIA Setup V11: MPS Aggregated GPU (single resource, per-GPU replicas)
# Feature: Uses 'kubectl rollout status' instead of sleep
# ==============================================================================
REPLICAS=${1:-20}           # per-GPU replicas (quota per card)
CUSTOM_PREFIX=${2:-gpu}     # aggregated resource uses default nvidia.com/gpu
TARGET_NODE=${3:-$(kubectl get nodes -o name | head -n 1 | cut -d/ -f2)}
PLUGIN_IMAGE_REPO=${4:-${PLUGIN_IMAGE_REPO:-docker.io/linskybing/k8s-device-plugin}}
PLUGIN_IMAGE_TAG=${5:-${PLUGIN_IMAGE_TAG:-mps-pack-strategy}}
# Optional: image pull secret for private registries (e.g., Harbor)
IMAGE_PULL_SECRET_NAME=${6:-${IMAGE_PULL_SECRET_NAME:-harbor-regcred}}
if [ "$REPLICAS" -lt 1 ]; then
  REPLICAS=1
fi

# Validate args
if [ -z "$CUSTOM_PREFIX" ] || [ -z "$TARGET_NODE" ] || [ -z "$PLUGIN_IMAGE_REPO" ]; then
  echo "[ERROR] Usage: ./03-install-gpu-drivers.sh <replicas-per-gpu> <resource-name> <node-name|all> <image-repo> [image-tag] [image-pull-secret]"
  echo "Example: ./03-install-gpu-drivers.sh 25 gpu gpu1 192.168.110.1:30003/library/k8s-device-plugin mps-pack-strategy harbor-regcred"
  echo "Example (all nodes): ./03-install-gpu-drivers.sh 25 gpu all 192.168.110.1:30003/library/k8s-device-plugin mps-pack-strategy harbor-regcred"
  echo "Hint: You can also set env PLUGIN_IMAGE_REPO, PLUGIN_IMAGE_TAG, IMAGE_PULL_SECRET_NAME instead of passing args 4/5/6."
  exit 1
fi

# Detect GPU count for per-GPU MPS entries
NUM_GPUS=$(nvidia-smi -L | wc -l)
TOTAL_TOKENS=$((REPLICAS * NUM_GPUS))
echo "========================================================"
echo "Strategy: JSON Patch + Kubectl Wait"
echo "Target Node: $TARGET_NODE"
echo "Plugin Image: $PLUGIN_IMAGE_REPO:$PLUGIN_IMAGE_TAG"
echo "Mode: MPS aggregated resource (nvidia.com/gpu), per-GPU replicas=$REPLICAS, total tokens=$TOTAL_TOKENS"
echo "========================================================"
command_exists() {
  command -v "$1" >/dev/null 2>&1
}
echo "[Step 1] Checking NVIDIA Drivers..."
if command_exists nvidia-smi; then
  CURRENT_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1)
  echo "Driver detected: v$CURRENT_DRIVER"
else
  echo "No driver detected. Installing recommended server driver..."
  sudo apt-get update
  sudo apt-get install -y ubuntu-drivers-common
  RECOMMENDED_DRIVER=$(ubuntu-drivers devices | grep "recommended" | awk '{print $3}')
  if [ -z "$RECOMMENDED_DRIVER" ]; then
    echo "Error: Could not detect a recommended driver. Install manually."
    exit 1
  fi
  sudo apt-get install -y "$RECOMMENDED_DRIVER"
  echo "DRIVER INSTALLED. REBOOT REQUIRED. Please reboot and re-run."
  exit 0
fi

echo "[Step 2] Configuring Container Runtime..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
sudo systemctl restart containerd
echo "[Step 3] Cleaning up old resources (mps/gpu)..."
helm uninstall nvidia-device-plugin -n kube-system 2>/dev/null || true
kubectl delete daemonset nvidia-device-plugin nvidia-device-plugin-mps-control-daemon -n kube-system 2>/dev/null || true
kubectl delete configmap nvidia-device-plugin-config nvidia-device-plugin-configs -n kube-system 2>/dev/null || true
sudo rm -f /var/lib/kubelet/device-plugins/nvidia.sock 2>/dev/null || true
kubectl label node "$TARGET_NODE" nvidia.com/mps.capable- 2>/dev/null || true
kubectl patch node "$TARGET_NODE" --type=json --subresource=status -p='[{"op":"remove","path":"/status/capacity/nvidia.com~1mps-0"},{"op":"remove","path":"/status/capacity/nvidia.com~1mps-1"},{"op":"remove","path":"/status/capacity/nvidia.com~1mps-2"},{"op":"remove","path":"/status/capacity/nvidia.com~1mps-3"},{"op":"remove","path":"/status/allocatable/nvidia.com~1mps-0"},{"op":"remove","path":"/status/allocatable/nvidia.com~1mps-1"},{"op":"remove","path":"/status/allocatable/nvidia.com~1mps-2"},{"op":"remove","path":"/status/allocatable/nvidia.com~1mps-3"}]' 2>/dev/null || true
# aggregated resource uses default nvidia.com/gpu; cleanup already handled above
kubectl patch node "$TARGET_NODE" --type=json --subresource=status -p='[
  {"op":"remove","path":"/status/capacity/nvidia.com~1gpu"},
  {"op":"remove","path":"/status/capacity/nvidia.com~1gpu-0"},
  {"op":"remove","path":"/status/capacity/nvidia.com~1gpu-1"},
  {"op":"remove","path":"/status/capacity/nvidia.com~1gpu-2"},
  {"op":"remove","path":"/status/capacity/nvidia.com~1gpu-3"},
  {"op":"remove","path":"/status/capacity/nvidia.com~1gpu.shared"},
  {"op":"remove","path":"/status/capacity/nvidia.com~1gpu1-0"},
  {"op":"remove","path":"/status/capacity/nvidia.com~1gpu1-1"},
  {"op":"remove","path":"/status/capacity/nvidia.com~1gpu1-2"},
  {"op":"remove","path":"/status/capacity/nvidia.com~1gpu1-3"},
  {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu"},
  {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu-0"},
  {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu-1"},
  {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu-2"},
  {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu-3"},
  {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu.shared"},
  {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu1-0"},
  {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu1-1"},
  {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu1-2"},
  {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu1-3"}
]' 2>/dev/null || true

echo "Waiting for old pods to terminate..."
kubectl delete pod -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin --force --grace-period=0 2>/dev/null || true
kubectl wait --for=delete pod -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin --timeout=90s 2>/dev/null || true

echo "[Step 3b] Resetting kubelet device-plugin state..."
if command -v systemctl >/dev/null 2>&1; then
  if [ "$TARGET_NODE" = "all" ]; then
    echo "Resetting kubelet on all GPU nodes (requires SSH access or manual restart)..."
    # For multi-node, you may need to SSH to each node or use ansible/pssh
    echo "[WARN] Multi-node kubelet restart not automated. Please restart kubelet on each GPU node manually if needed."
  else
    sudo systemctl stop kubelet || true
    sudo rm -f /var/lib/kubelet/device-plugins/nvidia*.sock 2>/dev/null || true
    sudo rm -f /var/lib/kubelet/device-plugins/kubelet_internal_checkpoint 2>/dev/null || true
    sudo rm -f /var/lib/kubelet/device-plugins/*.json 2>/dev/null || true
    sudo systemctl start kubelet || true
    kubectl wait --for=condition=Ready node/$TARGET_NODE --timeout=120s 2>/dev/null || true
  fi
else
  echo "[WARN] systemctl not found; please manually restart kubelet and clear /var/lib/kubelet/device-plugins if stale resources persist."
fi

echo "[Step 4] Building Helm values (config + image + node)..."
VALUES_FILE=$(mktemp /tmp/nvdp-values-XXXX.yaml)
CONFIG_KEY="aggregate-gpu-mps"
cat <<EOF > "$VALUES_FILE"
image:
  repository: "$PLUGIN_IMAGE_REPO"
  tag: "$PLUGIN_IMAGE_TAG"
  pullPolicy: IfNotPresent

config:
  default: "$CONFIG_KEY"
  fallbackStrategies:
    - named
  map:
    $CONFIG_KEY: |
      version: v1
      flags:
        migStrategy: none
        plugin:
          passDeviceSpecs: true
          deviceListStrategy:
            - envvar
            - cdi-annotations
          deviceIDStrategy: uuid
      resources:
        gpus:
          - pattern: "*"
            name: gpu
      sharing:
        mps:
          renameByDefault: false
          failRequestsGreaterThanOne: false
          resources:
            - name: nvidia.com/gpu
              replicas: ${REPLICAS}
              devices: "all"
nvidiaDriverRoot: "/"
affinity: null

gfd:
  enabled: false
nfd:
  enabled: false

mps:
  root: "/run/nvidia/mps"

tolerations:
  - operator: Exists

EOF

if [ "$TARGET_NODE" != "all" ]; then
  cat <<EOF >> "$VALUES_FILE"
nodeSelector:
  kubernetes.io/hostname: "$TARGET_NODE"
EOF
fi

cat <<EOF >> "$VALUES_FILE"
podSecurityContext:
  runAsNonRoot: false

securityContext:
  privileged: true
  capabilities:
    add:
      - SYS_ADMIN
      - SYS_RAWIO
  allowPrivilegeEscalation: true

imagePullSecrets:
  - name: "$IMAGE_PULL_SECRET_NAME"

EOF

echo "[Step 5] Installing Helm Chart..."
if [ "$TARGET_NODE" = "all" ]; then
  echo "Labeling all GPU nodes with nvidia.com/mps.capable=true..."
  kubectl get nodes -o json | jq -r '.items[] | select(.status.allocatable | has("nvidia.com/gpu") or has("feature.node.kubernetes.io/pci-10de.present")) | .metadata.name' | while read -r node; do
    kubectl label node "$node" nvidia.com/mps.capable=true --overwrite
  done
else
  kubectl label node "$TARGET_NODE" nvidia.com/mps.capable=true --overwrite
fi
helm upgrade --install nvidia-device-plugin /home/user/k8s-gpu-platform/k8s-device-plugin/deployments/helm/nvidia-device-plugin \
  --namespace kube-system \
  --create-namespace \
  -f "$VALUES_FILE" \
  --wait --timeout 180s

echo "[Step 5b] Waiting for DaemonSets to become Ready..."
kubectl rollout status ds/nvidia-device-plugin -n kube-system --timeout=120s || true
kubectl rollout status ds/nvidia-device-plugin-mps-control-daemon -n kube-system --timeout=120s || true

echo "[Step 6] Verifying Node Resources..."
VERIFY_NODES="$TARGET_NODE"
if [ "$TARGET_NODE" = "all" ]; then
  VERIFY_NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.metadata.labels["nvidia.com/mps.capable"] == "true") | .metadata.name' | tr '\n' ' ')
fi

for node in $VERIFY_NODES; do
  if kubectl describe node "$node" | grep -q "nvidia.com/${CUSTOM_PREFIX}"; then
    echo "--------------------------------------------------------"
    echo "Node: $node - Configured Resources:"
    kubectl describe node "$node" | grep "nvidia.com/${CUSTOM_PREFIX}"
    echo "--------------------------------------------------------"
  else
    echo "[WARNING] Node $node: Resources not visible yet."
    echo "Please check logs: kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin"
  fi
done
echo "Setup Complete."


# cd /home/user/k8s/k8s-device-plugin && docker build -t nvidia/k8s-device-plugin -f deployments/container/Dockerfile .