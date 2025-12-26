#!/bin/bash
set -e

# --- Configuration ---
# Default to 20 slices PER GPU. If you have 4 GPUs, total capacity will be 80.
REPLICAS=${1:-20}
RESOURCE_NAME=${2:-"nvidia.com/gpu"}
RENAME_TO=${3:-"nvidia.com/gpu.shared"}
RAW_NODE_NAME=${4:-$(hostname)}
# Force Node Name to lowercase (K8s requirement)
NODE_NAME=$(echo "$RAW_NODE_NAME" | tr '[:upper:]' '[:lower:]')

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  cat <<USAGE
Usage: $0 [REPLICAS] [RESOURCE_NAME] [RENAME_TO] [NODE_NAME]

Examples:
  $0 10 nvidia.com/gpu nvidia.com/gpu.shared gpu1
  $0                # uses defaults and current hostname (auto-lowercased)
USAGE
  exit 0
fi

echo "========================================================"
echo "   NVIDIA GPU Setup: Golden Config Overwrite Mode       "
echo "========================================================"
echo "Node (Raw):    $RAW_NODE_NAME"
echo "Node (K8s):    $NODE_NAME"
echo "Slices per GPU: $REPLICAS"
echo "Resource Name:  $RESOURCE_NAME"
echo "Renaming To:    $RENAME_TO"
echo "--------------------------------------------------------"

# --- 1. Clean up Host State ---
echo "[Step 1] Cleaning up GPU state..."

if pgrep -f "nvidia-cuda-mps-control"; then
    echo "Stopping legacy Host MPS daemon..."
    echo quit | sudo nvidia-cuda-mps-control || true
    sudo killall nvidia-cuda-mps-control 2>/dev/null || true
fi

# Reset GPU Compute Mode to Default
sudo nvidia-smi -c 0

# Clean up MPS pipes
sudo rm -rf /run/nvidia/mps

# [CRITICAL] Clean up CNI cache to prevent Network errors
echo "Cleaning up CNI results..."
sudo rm -rf /var/lib/cni/results/*

# --- 2. Install/Update Nvidia Container Toolkit ---
echo "[Step 2] Configuring Container Runtime..."

# Add Nvidia Repo
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# --- [FIX] Binary Path Correction ---
# Ensure the path used in config.toml actually exists
TARGET_BIN="/usr/bin/nvidia-container-runtime"
if [ ! -f "$TARGET_BIN" ]; then
    echo "Configuring binary symlink..."
    REAL_BIN=$(which nvidia-container-toolkit || which nvidia-container-runtime-hook)
    if [ -n "$REAL_BIN" ]; then
        sudo ln -sf "$REAL_BIN" "$TARGET_BIN"
        echo "Linked $TARGET_BIN -> $REAL_BIN"
    else
        echo "[ERROR] Could not find nvidia-container-toolkit binary!"
        exit 1
    fi
fi

# --- [FIX] Golden Configuration Overwrite ---
echo "Writing 'Golden' Containerd Config (Direct Overwrite)..."
sudo mkdir -p /etc/containerd
sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak_$(date +%s) 2>/dev/null || true

# 直接寫入一份保證能用的設定檔，不依賴 nvidia-ctk 自動生成
sudo bash -c 'cat > /etc/containerd/config.toml <<EOF
version = 2
[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "registry.k8s.io/pause:3.9"
    [plugins."io.containerd.grpc.v1.cri".containerd]
      # [CRITICAL] Default to nvidia so the Plugin Pod can load drivers
      default_runtime_name = "nvidia"
      snapshotter = "overlayfs"
      
      # --- NVIDIA Runtime Config ---
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
        privileged_without_host_devices = false
        runtime_type = "io.containerd.runc.v2"
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
          BinaryName = "/usr/bin/nvidia-container-runtime"
          SystemdCgroup = true

      # --- Standard Runc Config ---
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
        runtime_type = "io.containerd.runc.v2"
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
          SystemdCgroup = true
EOF'

# Restart Services
echo "Restarting Containerd & Kubelet..."
sudo systemctl restart containerd
sudo systemctl restart kubelet

# --- 3. Install Helm ---
echo "[Step 3] Ensuring Helm is installed..."
if ! command -v helm &> /dev/null; then
    curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
    sudo apt-get update
    sudo apt-get install helm -y
fi

# --- 4. Deploy Nvidia Device Plugin (Time-Slicing) ---
echo "[Step 4] Deploying Device Plugin..."

# Clean uninstall first to ensure ConfigMap updates properly
echo "Removing old installation..."
helm uninstall nvidia-device-plugin -n kube-system 2>/dev/null || true
# Wait for pod termination
sleep 10

# Prepare Helm Values
VALUES_FILE="/tmp/nvidia-values.yaml"
cat <<EOF > "$VALUES_FILE"
# Config for Time-Slicing (Sharing GPUs)
config:
  map:
    default: |-
      version: v1
      sharing:
        timeSlicing:
          resources:
            - name: $RESOURCE_NAME
              replicas: $REPLICAS
              rename: $RENAME_TO

# Enable compatibility features
compatWithCPUManager: true
EOF

# Update Repo
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

# Install
helm install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --create-namespace \
  --version 0.14.5 \
  -f "$VALUES_FILE"

# --- 5. Verify ---
echo "[Step 5] Verification..."
echo "Waiting for plugin to initialize..."
sleep 15

if command -v kubectl &> /dev/null; then
    echo "Checking Node Capacity..."
    # Attempt to get capacity
    kubectl get node "$NODE_NAME" -o json | jq '.status.capacity' | grep "nvidia" || echo "Capacity not updated yet. Please run 'kubectl describe node $NODE_NAME' manually."
else
    echo "kubectl not found. Please run 'kubectl get nodes -o json' on master to verify capacity."
fi

echo "========================================================"
echo "Setup Complete."
echo "If you have 4 GPUs, you should see total capacity: $(( 4 * REPLICAS ))"
echo "Resource Name: $RENAME_TO"
echo "========================================================"