#!/bin/bash
set -e

# --- Argument Handling ---
REPLICAS=${1:-10}
RESOURCE_NAME=${2:-"nvidia.com/gpu"}
RENAME_TO=${3:-"nvidia.com/gpu.shared"}

echo "------------------------------------------------"
echo "GPU Replicas: $REPLICAS"
echo "Resource Name: $RESOURCE_NAME"
echo "Rename To: $RENAME_TO"
echo "------------------------------------------------"

# --- 1. System Cleanup ---
echo "[STEP 1] Deep cleaning host and resetting GPU..."
NODE_NAME=$(hostname)

# Kill host MPS and reset compute mode
sudo nvidia-cuda-mps-control -quit || true
sudo nvidia-smi -c EXCLUSIVE_PROCESS
sudo nvidia-smi -pm 1

# Completely wipe and recreate the MPS directory
sudo rm -rf /run/nvidia/mps
sudo mkdir -p /run/nvidia/mps/log
sudo chmod -R 777 /run/nvidia/mps

# Start MPS Daemon on Host
echo "Starting MPS Daemon on Host..."
export CUDA_MPS_PIPE_DIRECTORY=/run/nvidia/mps
export CUDA_MPS_LOG_DIRECTORY=/run/nvidia/mps/log
sudo -E nvidia-cuda-mps-control -d
echo "MPS Daemon started."

# Clear K8s taints/labels/sockets
kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane- || true
kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/master- || true
kubectl label node "$NODE_NAME" nvidia.com/gpu.present=true --overwrite
sudo rm -rf /var/lib/kubelet/device-plugins/nvidia*

# --- 2. Runtime Configuration ---
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
sudo systemctl restart containerd

# --- 3. Helm Deployment (V7 - Open Driver Compatibility) ---
echo "[STEP 3] Deploying Device Plugin with Open-Driver patches..."

VALUES_FILE="/tmp/nvdp-v7-open.yaml"
cat <<EOF > $VALUES_FILE
nodeSelector: {}
tolerations:
  - operator: Exists

# High-level permissions
privileged: true
hostIPC: true
hostNetwork: true

# Security Profile (Crucial for Ubuntu AppArmor)
appArmorProfile:
  type: Unconfined

# Grant SYS_ADMIN for IPC management
capabilities:
  - SYS_ADMIN

# Explicitly map the host directory
mps:
  rootDirectory: /run/nvidia/mps

# Environment variables for Open-Kernel
devicePlugin:
  env:
    - name: NVIDIA_DRIVER_CAPABILITIES
      value: all
    - name: CUDA_MPS_PIPE_DIRECTORY
      value: /run/nvidia/mps

config:
  defaultConfig: default
  map:
    default: |-
      version: v1
      sharing:
        timeSlicing:
          resources:
            - name: $RESOURCE_NAME
              replicas: $REPLICAS
              rename: $RENAME_TO
EOF

helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

# Perform clean re-install
helm uninstall nvidia-device-plugin -n kube-system || true
helm install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  -f $VALUES_FILE

# --- 4. Final Service Restart ---
echo "[STEP 4] Restarting Kubelet..."
sudo systemctl restart kubelet

echo "Waiting 15 seconds for Open Driver handshake..."
sleep 15

# --- 5. Diagnostics ---
echo "--- Host Pipe Check (If empty, there's a driver/kernel block) ---"
ls -la /run/nvidia/mps

echo "--- Plugin Logs ---"
kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin -c nvidia-device-plugin-ctr --tail=20

echo "------------------------------------------------"
echo "Final Setup Result for $NODE_NAME:"
kubectl get nodes "$NODE_NAME" "-o=custom-columns=NAME:.metadata.name,GPU_SHARED_CAPACITY:.status.capacity.nvidia\.com/gpu"
echo "------------------------------------------------"