#!/bin/bash
set -e

echo "=== Tuning System Parameters for Kubernetes & Longhorn (Production) ==="

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

# 4. Longhorn Specific Check (Reminder)
echo "-------------------------------------------------------"
echo "System tuning complete."
echo "NOTE for Longhorn: Ensure 'open-iscsi' and 'nfs-common' are installed on this host."
echo "Command: sudo apt-get install -y open-iscsi nfs-common (for Ubuntu/Debian)"