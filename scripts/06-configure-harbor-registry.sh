#!/bin/bash
set -e

# Get the Master Node IP (Harbor IP)
# If running on master, we can detect it. If on worker, we might need it passed or hardcoded.
# For this script, we assume it's running on the cluster where kubectl is available OR we use the known IP.
# Since this script might run on a worker node where kubectl isn't configured yet, we should allow an override.

# Default to the known Master IP if not provided
HARBOR_IP=${1:-"10.121.124.10"}
HARBOR_PORT="30002"
REGISTRY_URL="http://$HARBOR_IP:$HARBOR_PORT"

echo "=== Configuring Containerd to Trust Harbor Registry ($REGISTRY_URL) ==="
echo "Note: This script must be run on ALL nodes (Master and Workers)."

# 1. Update config.toml to enable certs.d directory
CONFIG_FILE="/etc/containerd/config.toml"

if grep -q 'config_path = ""' "$CONFIG_FILE"; then
    echo "Enabling config_path in $CONFIG_FILE..."
    sudo sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|g' "$CONFIG_FILE"
elif grep -q 'config_path = "/etc/containerd/certs.d"' "$CONFIG_FILE"; then
    echo "config_path already set."
else
    echo "Warning: Could not find 'config_path' setting to update. Please check $CONFIG_FILE manually."
fi

# 2. Create hosts.toml for the registry
CERTS_DIR="/etc/containerd/certs.d/$HARBOR_IP:$HARBOR_PORT"
echo "Creating registry config in $CERTS_DIR..."
sudo mkdir -p "$CERTS_DIR"

cat <<EOF | sudo tee "$CERTS_DIR/hosts.toml"
server = "$REGISTRY_URL"

[host."$REGISTRY_URL"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

# 3. Restart Containerd
echo "Restarting containerd..."
sudo systemctl restart containerd

echo "Containerd configured to trust Harbor at $HARBOR_IP:$HARBOR_PORT"
