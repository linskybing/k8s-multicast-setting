#!/bin/bash

# ==============================================================================
# K8s GPU Cluster Network Optimization Script
# Purpose: Fix MTU issues, RP Filter blocking, and IPIP Protocol filtering
# Target: GPU1, GPU2, GPU3 (Ubuntu 24.04 + Calico IPIP)
# ==============================================================================

echo "Starting Network Optimization..."

# 1. Standardize Kernel Parameters (Sysctl)
echo "[1/4] Applying Kernel Parameters (RP Filter & IP Forwarding)..."
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-calico.conf
# Disable Reverse Path Filtering to allow IPIP encapsulated packets
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
# Enable IP Forwarding for Pod-to-Pod communication
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

# 2. Configure Firewall & IPIP Protocol (iptables)
echo "[2/4] Configuring Firewall for IPIP Protocol 4..."
# Allow Protocol 4 (IPIP) - Crucial for Calico IPIP mode
sudo iptables -I INPUT -p 4 -j ACCEPT
sudo iptables -I FORWARD -p 4 -j ACCEPT

# Trust the 25Gbps Internal Subnet (Replace with your actual range if different)
sudo iptables -I INPUT -s 192.168.110.0/24 -j ACCEPT

# If UFW is active, allow the 25G subnet
if command -v ufw > /dev/null; then
    sudo ufw allow from 192.168.110.0/24
fi

# 3. Standardize Host MTU (tunl0)
echo "[3/4] Adjusting tunl0 MTU to 1400..."
if ip link show tunl0 > /dev/null 2>&1; then
    sudo ip link set dev tunl0 mtu 1400
    sudo ip link set dev tunl0 up
fi

# 4. Persistence for iptables (Ubuntu)
echo "[4/4] Installing iptables-persistent to save rules..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
sudo netfilter-persistent save

echo "--------------------------------------------------"
echo "Network Optimization Completed Successfully!"
echo "Please verify by pinging Pod IPs across nodes."

#sudo ethtool -K enp193s0f0np0 tx off rx off gro off lro off

# 在 GPU2 執行
sudo sysctl -w net.ipv4.conf.all.rp_filter=0
sudo sysctl -w net.ipv4.conf.default.rp_filter=0
sudo sysctl -w net.ipv4.conf.enp193s0f0np0.rp_filter=0
sudo sysctl -w net.ipv4.conf.tunl0.rp_filter=0
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -p