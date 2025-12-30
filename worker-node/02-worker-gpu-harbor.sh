#!/bin/bash
set -e

# --- Configuration ---
# Align with 06-configure-harbor-registry.sh and production network
HARBOR_IP=${1:-"192.168.109.1"}
HARBOR_PORT="30002"
# Specify a stable driver version (e.g., 550) for production consistency
DRIVER_VERSION="550"

echo "=== [Phase 3] Configuring GPU Support & Harbor Registry ==="

# 1. Install NVIDIA Driver (CRITICAL: Fixes "nvidia-smi failed")
echo ">>> Installing NVIDIA Driver $DRIVER_VERSION..."
sudo apt-get update -qq
sudo apt-get install -y "nvidia-driver-$DRIVER_VERSION" linux-headers-$(uname -r)

# 2. Install NVIDIA Container Toolkit
echo ">>> Installing NVIDIA Container Toolkit..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

# 3. Configure NVIDIA as the default containerd runtime
echo ">>> Configuring Containerd runtime..."
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default

# 4. Generate CDI Specification (CRITICAL: Fixes "unresolvable CDI devices" error)
# This allows Kubernetes to map GPU devices to containers correctly
echo ">>> Generating CDI specification..."
sudo mkdir -p /etc/cdi
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# 5. Trust Harbor Insecure Registry (HTTP)
echo ">>> Configuring Harbor registry trust..."
sudo sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|g' /etc/containerd/config.toml
TARGET_DIR="/etc/containerd/certs.d/$HARBOR_IP:$HARBOR_PORT"
sudo mkdir -p "$TARGET_DIR"

cat <<EOF | sudo tee "$TARGET_DIR/hosts.toml" > /dev/null
server = "http://$HARBOR_IP:$HARBOR_PORT"
[host."http://$HARBOR_IP:$HARBOR_PORT"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

# 6. Restart Services to apply all changes
echo ">>> Restarting services..."
sudo systemctl restart containerd
sudo systemctl restart kubelet

echo "-------------------------------------------------------"
echo ">>> Phase 3 Complete: GPU Driver, CDI, and Registry configured."
echo "CRITICAL: You MUST run 'sudo reboot' to activate the NVIDIA driver."
echo "-------------------------------------------------------"