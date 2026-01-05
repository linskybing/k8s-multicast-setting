#!/bin/bash
set -e

# --- Configuration ---
HARBOR_IP=${1:-"192.168.109.1"}
HARBOR_PORT="30002"
# Note: Ensure this version exists in your apt cache. 
# 550 is a common LTS; 580 is bleeding edge.
DRIVER_VERSION="580" 

echo "=== [Phase 3] Configuring GPU Support & Harbor Registry ==="

# --- 0. Pre-flight Checks ---
echo ">>> Checking dependencies..."
sudo apt-get update -qq
sudo apt-get install -y curl gpg ca-certificates

# --- 1. Install NVIDIA Driver ---
echo ">>> Installing NVIDIA Driver $DRIVER_VERSION..."
# Check if the specific package exists to avoid breaking halfway
if apt-cache show "nvidia-driver-$DRIVER_VERSION" >/dev/null 2>&1; then
    sudo apt-get install -y "nvidia-driver-$DRIVER_VERSION" linux-headers-$(uname -r)
else
    echo "ERROR: nvidia-driver-$DRIVER_VERSION not found in repositories."
    echo "Available versions:"
    apt-cache search nvidia-driver | grep -oP 'nvidia-driver-\d+' | sort -u | tail -n 5
    exit 1
fi

# --- 2. Install NVIDIA Container Toolkit ---
echo ">>> Installing NVIDIA Container Toolkit..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

# --- 3. Configure NVIDIA as default Containerd runtime ---
echo ">>> Configuring Containerd runtime..."
# Backup config before modifying
if [ -f /etc/containerd/config.toml ]; then
    sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
else
    # Generate default if missing
    sudo mkdir -p /etc/containerd
    sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
fi
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default

# --- 4. Load Kernel Modules & Generate CDI ---
echo ">>> Attempting to load NVIDIA kernel modules for CDI generation..."
# CRITICAL: We must load modules now to generate CDI without a reboot
# If this fails, the user must reboot and regenerate CDI manually.
set +e # Temporarily allow failure for modprobe
sudo modprobe nvidia
sudo modprobe nvidia_uvm
MODPROBE_STATUS=$?
set -e

echo ">>> Generating CDI specification..."
sudo mkdir -p /etc/cdi
if [ $MODPROBE_STATUS -eq 0 ]; then
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
    echo "   [OK] CDI generated successfully."
else
    echo "   [WARNING] Could not load NVIDIA drivers (restart likely required first)."
    echo "   [ACTION] CDI spec generated potentially empty. Kubernetes may not see GPUs until reboot."
    # Generate it anyway, but it might just be the scaffold
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml || true
fi

# --- 5. Trust Harbor Insecure Registry (Idempotent) ---
echo ">>> Configuring Harbor registry trust..."
CONFIG_TOML="/etc/containerd/config.toml"
SEARCH_PATTERN='config_path = ""'
REPLACE_PATTERN='config_path = "/etc/containerd/certs.d"'

# Only perform sed if we haven't already configured config_path
if grep -Fq "$SEARCH_PATTERN" "$CONFIG_TOML"; then
    sudo sed -i "s|$SEARCH_PATTERN|$REPLACE_PATTERN|g" "$CONFIG_TOML"
    echo "   [OK] Updated config_path in config.toml"
elif grep -Fq "$REPLACE_PATTERN" "$CONFIG_TOML"; then
    echo "   [SKIP] config_path already configured."
else
    echo "   [WARNING] Could not find 'config_path = \"\"' in config.toml. Check file manually."
fi

TARGET_DIR="/etc/containerd/certs.d/$HARBOR_IP:$HARBOR_PORT"
sudo mkdir -p "$TARGET_DIR"

echo "   [INFO] Writing hosts.toml for $HARBOR_IP:$HARBOR_PORT"
cat <<EOF | sudo tee "$TARGET_DIR/hosts.toml" > /dev/null
server = "http://$HARBOR_IP:$HARBOR_PORT"
[host."http://$HARBOR_IP:$HARBOR_PORT"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

# --- 6. Restart Services ---
echo ">>> Restarting services..."
sudo systemctl daemon-reload
sudo systemctl restart containerd
sudo systemctl restart kubelet

echo "-------------------------------------------------------"
echo ">>> Phase 3 Complete."
echo "1. Verify Harbor access: sudo crictl pull $HARBOR_IP:$HARBOR_PORT/library/hello-world:latest (if exists)"
echo "2. Verify CDI: cat /etc/cdi/nvidia.yaml"
echo "3. CRITICAL: RUN 'sudo reboot' NOW to finalize driver installation."
echo "-------------------------------------------------------"