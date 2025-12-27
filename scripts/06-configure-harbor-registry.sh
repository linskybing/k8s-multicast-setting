#!/bin/bash
set -e

# ==============================================================================
# SCRIPT: Production Containerd Registry Config
# SCOPE:  Configures Containerd to trust insecure Harbor (HTTP)
# SAFETY: Includes backup & auto-rollback on failure
# ==============================================================================

# --- Configuration ---
HARBOR_IP=${1:-"192.168.109.1"}
HARBOR_PORT="30002"
REGISTRY_URL="http://$HARBOR_IP:$HARBOR_PORT"

CONFIG_FILE="/etc/containerd/config.toml"
BACKUP_FILE="$CONFIG_FILE.bak.$(date +%F_%T)"
CERTS_BASE_DIR="/etc/containerd/certs.d"

echo ">>> Configuring Containerd for Registry: $REGISTRY_URL"

# --- 1. Validation & Backup ---

# Generate default config if missing (common on some K8s distros)
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[WARN] No config found. Generating default..."
    sudo mkdir -p /etc/containerd
    sudo containerd config default | sudo tee "$CONFIG_FILE" > /dev/null
fi

# Create Backup
echo "[INFO] Backing up current config to $BACKUP_FILE"
sudo cp "$CONFIG_FILE" "$BACKUP_FILE"

# --- 2. Update config.toml ---

# We only replace 'config_path = ""' to ensure we target the default registry setting
# and avoid accidentally breaking other plugins (Production Safety).
if grep -q 'config_path = ""' "$CONFIG_FILE"; then
    echo "[INFO] Updating registry config path..."
    sudo sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|g' "$CONFIG_FILE"
elif grep -q 'config_path = "/etc/containerd/certs.d"' "$CONFIG_FILE"; then
    echo "[INFO] Config path already set. Skipping."
else
    echo "[WARN] unexpected config_path found. Manual check recommended."
fi

# --- 3. Create Registry Host Config ---

# Define directory for this specific registry
TARGET_DIR="$CERTS_BASE_DIR/$HARBOR_IP:$HARBOR_PORT"
sudo mkdir -p "$TARGET_DIR"

echo "[INFO] Writing hosts.toml to $TARGET_DIR..."

# 'skip_verify = true' is required for HTTP/Insecure registries
cat <<EOF | sudo tee "$TARGET_DIR/hosts.toml" > /dev/null
server = "$REGISTRY_URL"

[host."$REGISTRY_URL"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

# --- 4. Restart & Health Check ---

echo "[INFO] Restarting Containerd..."
sudo systemctl restart containerd

# Verify service health. If failed, rollback immediately.
if systemctl is-active --quiet containerd; then
    echo "Success! Containerd is running."
    echo "   Registry configured at: $TARGET_DIR/hosts.toml"
else
    echo "[CRITICAL] Containerd failed to start."
    echo "   Restoring configuration from backup..."
    sudo cp "$BACKUP_FILE" "$CONFIG_FILE"
    sudo systemctl restart containerd
    echo "   Rollback complete. System returned to previous state."
    exit 1
fi