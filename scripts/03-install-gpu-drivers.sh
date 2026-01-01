#!/bin/bash
set -e

# --- Configuration ---
# Use standard 'nvidia.com/gpu' to allow automatic exclusion
RESOURCE_NAME="nvidia.com/gpu"
REPLICAS=${1:-20}

echo "========================================================"
echo "   NVIDIA GPU Setup: MPS Mode (Fixed)"
echo "   Strategy: MPS (Logical Isolation)"
echo "   Replicas per GPU: $REPLICAS"
echo "========================================================"

# --- Helper Functions ---
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# --- 1. Driver Installation (Headless/Server) ---
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

# --- 2. Configure NVIDIA Container Toolkit ---
echo "[Step 2] Configuring Container Runtime..."

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
sudo systemctl restart containerd

# --- 3. Kubernetes Connectivity Check ---
echo "[Step 3] Checking Kubernetes Connectivity..."
if ! command_exists kubectl; then
    echo "Error: kubectl not found."
    exit 1
fi

echo "Waiting for Kubelet..."
for i in {1..30}; do
    if sudo systemctl is-active --quiet kubelet; then
        break
    fi
    sleep 2
done

# --- 4. Install Helm ---
echo "[Step 4] Checking Helm..."
if ! command_exists helm; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- 5. Deploy Device Plugin with MPS ---
echo "[Step 5] Deploying NVIDIA Device Plugin (MPS)..."

# Clean up previous install to avoid conflicts
helm uninstall nvidia-device-plugin -n kube-system 2>/dev/null || true
sleep 3

# Prepare values.yaml
# FIX: We removed 'config.name'. We only provide 'config.map'.
VALUES_FILE="/tmp/nvidia-mps-values.yaml"

cat <<EOF > "$VALUES_FILE"
config:
  map:
    default: |-
      version: v1
      sharing:
        mps:
          resources:
            - name: $RESOURCE_NAME
              replicas: $REPLICAS
compatWithCPUManager: true
gfd:
  enabled: true
EOF

echo "Generated Configuration:"
cat "$VALUES_FILE"

# Add Repo and Install
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

echo "Applying Helm Chart..."
helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --create-namespace \
  -f "$VALUES_FILE" \
  --wait

echo "========================================================"
echo "Setup Complete."
echo "--------------------------------------------------------"
echo "Total Capacity: $(kubectl get node $(hostname | tr '[:upper:]' '[:lower:]') -o jsonpath='{.status.capacity}' | grep $RESOURCE_NAME)"
echo ""
echo "USAGE (4 GPUs Example):"
echo "1. Dedicated (Takes 1 Full Physical Card):"
echo "   resources: { $RESOURCE_NAME: $REPLICAS }"
echo ""
echo "2. Shared (Takes 1 Slice via MPS):"
echo "   resources: { $RESOURCE_NAME: 1 }"
echo "========================================================"