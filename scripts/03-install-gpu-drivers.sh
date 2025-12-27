#!/bin/bash
set -e

# --- Configuration ---
REPLICAS=${1:-20}
RESOURCE_NAME=${2:-"nvidia.com/gpu"}
RENAME_TO=${3:-"nvidia.com/gpu.shared"}
RAW_NODE_NAME=${4:-$(hostname)}
NODE_NAME=$(echo "$RAW_NODE_NAME" | tr '[:upper:]' '[:lower:]')

echo "========================================================"
echo "   NVIDIA GPU Setup: Safe Configuration Mode            "
echo "========================================================"

# --- 1. Clean up Host State ---
echo "[Step 1] Cleaning up GPU state..."
sudo nvidia-smi -c 0 || true

# --- 2. Install/Update Nvidia Container Toolkit ---
echo "[Step 2] Configuring Container Runtime..."

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

echo "Configuring Containerd with nvidia-ctk..."
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default

# Restart Services
echo "Restarting Containerd & Kubelet..."
sudo systemctl restart containerd
sudo systemctl restart kubelet

# --- Wait for Node Readiness ---
echo ">>> Waiting for Node to be Ready..."
for i in {1..60}; do
    if kubectl get nodes &> /dev/null; then
        echo "Kubernetes API is UP!"
        break
    fi
    echo "Waiting for API server... ($i/60)"
    sleep 2
done

# --- 3. Install Helm ---
echo "[Step 3] Ensuring Helm is installed..."
if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- 4. Deploy Device Plugin ---
echo "[Step 4] Deploying Device Plugin..."

# Clean old installation
helm uninstall nvidia-device-plugin -n kube-system 2>/dev/null || true
sleep 5

# Prepare Values
VALUES_FILE="/tmp/nvidia-values.yaml"
cat <<EOF > "$VALUES_FILE"
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
compatWithCPUManager: true
EOF

helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --create-namespace \
  --version 0.14.5 \
  -f "$VALUES_FILE" \
  --wait

echo "========================================================"
echo "Setup Complete."
echo "If you have 4 GPUs, you should see total capacity: $(( 4 * REPLICAS ))"
echo "========================================================"