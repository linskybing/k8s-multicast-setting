#!/bin/bash
set -e

# ==============================================================================
# Containerd Registry Configuration Script
# Scope: Configures containerd to trust insecure (HTTP) Harbor registry
# Target: Must be run on ALL nodes (Master & Workers)
# ==============================================================================

# 1. Configuration
# Default to your specific Master IP if not provided as argument
HARBOR_IP=${1:-"10.121.124.10"}
HARBOR_PORT="30002"
REGISTRY_URL="http://$HARBOR_IP:$HARBOR_PORT"
CONFIG_FILE="/etc/containerd/config.toml"
BACKUP_FILE="$CONFIG_FILE.bak.$(date +%F_%T)"

echo "=== Configuring Containerd for Harbor ($REGISTRY_URL) ==="

# 2. Backup existing configuration (Production Safety)
if [ -f "$CONFIG_FILE" ]; then
    echo "[INFO] Backing up config.toml to $BACKUP_FILE..."
    sudo cp "$CONFIG_FILE" "$BACKUP_FILE"
else
    echo "[ERROR] $CONFIG_FILE not found! Is containerd installed?"
    exit 1
fi

# 3. Update config.toml to enable certs.d directory
# We use a robust regex to find 'config_path', even if it is commented out or has existing values.
echo "[STEP 1] Updating config_path in $CONFIG_FILE..."

# Check if we need to modify it
if grep -q 'config_path = "/etc/containerd/certs.d"' "$CONFIG_FILE"; then
    echo "[INFO] config_path is already set correctly."
else
    # This sed command searches for any line containing "config_path =" inside the [plugins] section
    # and forces it to the correct directory. It handles indented lines too.
    sudo sed -i 's|.*config_path = .*|      config_path = "/etc/containerd/certs.d"|g' "$CONFIG_FILE"
    echo "[INFO] config_path updated."
fi

# 4. Create hosts.toml for the registry
# Containerd 1.5+ uses this structure to define registry capabilities and mirror settings
CERTS_DIR="/etc/containerd/certs.d/$HARBOR_IP:$HARBOR_PORT"
echo "[STEP 2] Creating registry config in $CERTS_DIR..."
sudo mkdir -p "$CERTS_DIR"

cat <<EOF | sudo tee "$CERTS_DIR/hosts.toml" > /dev/null
server = "$REGISTRY_URL"

[host."$REGISTRY_URL"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

# 5. Restart Containerd
echo "[STEP 3] Restarting containerd service..."
sudo systemctl restart containerd

# 6. Verification
echo "----------------------------------------------------------------"
echo "Configuration Complete!"
echo "Registry: $REGISTRY_URL"
echo "Config:   $CERTS_DIR/hosts.toml"
echo ""
echo "To verify connectivity, try pulling an image manually on this node:"
echo "  sudo crictl pull $HARBOR_IP:$HARBOR_PORT/library/hello-world:latest"
echo "  (Note: You need to push an image to Harbor first)"
echo "----------------------------------------------------------------"