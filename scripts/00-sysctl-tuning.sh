#!/bin/bash
set -e

echo "=== Tuning System Parameters for Kubernetes & Longhorn ==="

# Increase inotify watches (Fixes: Failed to allocate directory watch: Too many open files)
# This is critical for Kubernetes, Longhorn, and monitoring stacks which watch many files.
echo "Configuring sysctl limits..."

cat <<EOF | sudo tee /etc/sysctl.d/99-k8s-tuning.conf
# Increase inotify limits for file watching (Tail, Logs, CSI drivers)
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192

# Increase maximum number of open files
fs.file-max = 100000
EOF

# Apply changes immediately
echo "Applying sysctl changes..."
sudo sysctl --system

echo "=== Tuning Complete ==="
