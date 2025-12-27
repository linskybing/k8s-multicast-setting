#!/bin/bash
set -e

echo "=== Tuning System Parameters for Kubernetes & Longhorn (Production) ==="

# 0. [CRITICAL] Disable Swap Permanently (Fixes K8s reboot failure)
echo ">>> Disabling Swap permanently..."
# Turn off swap immediately
sudo swapoff -a
# Comment out swap partitions in /etc/fstab to prevent mounting on reboot
# This ensures Kubelet starts correctly after every reboot
sudo sed -i '/swap/ s/^/#/' /etc/fstab || true

# 1. Load required kernel modules first (Critical for networking)
echo ">>> Loading kernel modules..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# 2. Configure sysctl params
echo ">>> Configuring sysctl limits..."

cat <<EOF | sudo tee /etc/sysctl.d/99-k8s-tuning.conf
# --- Networking (CRITICAL for K8s CNI) ---
# Allow IP forwarding (Required for Pod-to-Pod communication)
net.ipv4.ip_forward = 1

# Ensure iptables tooling sees bridged traffic
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1

# --- File System Watches (Critical for Logs & Storage) ---
# Increase inotify limits (Fixes: "Too many open files" in log collectors/Longhorn)
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192

# --- Open Files Limits ---
# Set to 2 Million (100k is too low for production storage nodes)
# If your server has >64GB RAM, you can increase this further.
fs.file-max = 2097152

# --- Virtual Memory (Optional but recommended for DBs/Elasticsearch) ---
# Prevent swapping as much as possible (K8s hates swap)
vm.swappiness = 0
EOF

# 3. Apply changes
echo ">>> Applying sysctl changes..."
sudo sysctl --system

# 4. Enable Services to Start on Boot (Fixes 'connection refused' after reboot)
echo ">>> Enabling Kubelet & Containerd auto-start..."
sudo systemctl daemon-reload
sudo systemctl enable kubelet
sudo systemctl enable containerd
# If Docker is installed, enable it too (optional)
if systemctl list-unit-files | grep -q docker.service; then
  sudo systemctl enable docker
fi

# 5. Install Longhorn Dependencies (Auto-install)
echo ">>> Installing dependencies for Longhorn (iSCSI & NFS)..."
sudo apt-get update
sudo apt-get install -y open-iscsi nfs-common
# Ensure iscsid service is running (Required by Longhorn)
sudo systemctl enable --now iscsid

echo "-------------------------------------------------------"
echo "System tuning & Initialization complete!"
echo "Status: Swap Disabled | Modules Loaded | Services Enabled | Deps Installed"