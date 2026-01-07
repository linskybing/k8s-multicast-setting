#!/bin/bash
set -e

echo "=== [Phase 1] Tuning System for Worker Node ==="

# 1. Permanently disable swap to ensure Kubelet stability
sudo swapoff -a
sudo sed -i '/swap/ s/^/#/' /etc/fstab || true

# 2. Load essential kernel modules for networking
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# 3. Configure sysctl parameters (networking & file limits)
cat <<EOF | sudo tee /etc/sysctl.d/99-k8s-tuning.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
fs.file-max = 2097152
vm.swappiness = 0
EOF
sudo sysctl --system

# 4. Install Longhorn storage dependencies (iSCSI & NFS)
sudo apt-get update -qq
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

# ================= CONFIGURATION =================
# The subnet used for internal cluster communication (IPIP Tunnel)
INTERCONNECT_CIDR="192.168.110.0/24"

# Interface names (Adjust if your nodes use different names)
IFACE_STORAGE="enp193s0f0np0"
IFACE_INTERNAL="enp193s0f1np1"
# =================================================

echo "=== System Network Hardening (Run on ALL Nodes) ==="
echo "Target Subnet: $INTERCONNECT_CIDR"

echo "--> 1. Configuring Kernel Parameters (Persistent)..."
# We write to /etc/sysctl.d/ so settings survive reboots.
# rp_filter=2 (Loose mode) is critical for asymmetric routing in multi-homed K8s.
cat <<EOF | sudo tee /etc/sysctl.d/99-k8s-calico-tuning.conf
# Enable IP forwarding (Required for Routers/K8s)
net.ipv4.ip_forward = 1

# Loose Reverse Path Filter (Fixes packet drops in Multi-NIC setups)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.${IFACE_STORAGE}.rp_filter = 2
net.ipv4.conf.${IFACE_INTERNAL}.rp_filter = 2
EOF

# Apply changes immediately without reboot
sudo sysctl --system > /dev/null
echo "    [OK] Kernel parameters updated and applied."

echo "--> 2. Configuring Firewall (iptables)..."
# Explicitly allow IPIP Protocol (4) from the internal network.
# This prevents the "Drop IPIP packets from non-Calico hosts" error.

if ! sudo iptables -C INPUT -p 4 -s $INTERCONNECT_CIDR -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT -p 4 -s $INTERCONNECT_CIDR -j ACCEPT
    echo "    [OK] iptables rule added: Allow Protocol 4 from $INTERCONNECT_CIDR"
else
    echo "    [SKIP] iptables rule already exists."
fi

echo "--> 3. Saving Firewall Rules (Persistence)..."
# Check if iptables-persistent is installed to save rules across reboots.
if dpkg -s iptables-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save
    echo "    [OK] Rules saved to /etc/iptables/rules.v4"
else
    echo "    [WARN] 'iptables-persistent' is NOT installed."
    echo "           The IPIP allow rule will be lost after reboot."
    echo "           Please run: sudo apt update && sudo apt install iptables-persistent -y"
fi

echo "======================================================="
echo "OS HARDENING COMPLETE."
echo "Please verify this script has been run on ALL nodes."
echo "======================================================="
echo ">>> Phase 1 Complete: System optimized and storage dependencies ready."