#!/bin/bash
set -e

# ================= CONFIGURATION =================
CALICO_VERSION="v3.27.0"
POD_CIDR=${POD_CIDR:-"10.244.0.0/16"}
# [Key Configuration] Lock to the Cluster Internal Interface (Port 2)
IP_AUTODETECTION_METHOD="interface=enp193s0f1np1"

# Force IPIP Mode and safer MTU
CALICO_IPV4POOL_IPIP="Always"
CALICO_MTU="1440" # Reserve space for encapsulation headers (Total 1500 - 60 safety buffer)
INTERCONNECT_CIDR="192.168.110.0/24" # Your interconnect subnet
# =================================================

echo "=== [PART 1] System Level Hardening (Run on ALL Nodes) ==="
# This section MUST be executed on EVERY node (GPU1, GPU2, GPU3).
# It configures kernel parameters and firewall rules that persist after reboot.

echo "--> 1. Persisting Kernel Parameters (rp_filter)..."
# Write to a sysctl config file to ensure settings persist after reboot
# We set rp_filter to 2 (Loose mode) to fix multi-homed routing issues.
cat <<EOF | sudo tee /etc/sysctl.d/99-k8s-calico-tuning.conf
# Enable IP forwarding
net.ipv4.ip_forward = 1
# Loose Reverse Path Filter for multi-homed K8s nodes (Calico + Multus)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.enp193s0f0np0.rp_filter = 2
net.ipv4.conf.enp193s0f1np1.rp_filter = 2
EOF

# Apply changes immediately
sudo sysctl --system > /dev/null
echo "    Kernel parameters updated and persisted."

echo "--> 2. Ensuring IPIP Traffic is Allowed (Fail-safe)..."
# Explicitly allow IPIP protocol (Proto 4) from the interconnect subnet.
# This prevents the firewall from dropping packets if Calico's auto-detection fails.
if ! sudo iptables -C INPUT -p 4 -s $INTERCONNECT_CIDR -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT -p 4 -s $INTERCONNECT_CIDR -j ACCEPT
    echo "    iptables rule added."
else
    echo "    iptables rule already exists."
fi

# Attempt to persist iptables rules (if iptables-persistent is installed)
if dpkg -s iptables-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save
    echo "    iptables rules saved to disk."
else
    echo "    [WARN] iptables-persistent not found. Rule is active but may be lost on reboot."
    echo "    Recommend installing: sudo apt install iptables-persistent -y"
fi

echo "=== [PART 2] Kubernetes Cluster Config (Run ONCE on Master) ==="

# Check if we can access the K8s API. If not (e.g., running on a Worker node), skip this part.
if ! kubectl get nodes >/dev/null 2>&1; then
    echo "[INFO] kubectl not accessible or running on a worker node. Skipping Cluster Manifest steps."
    echo "       System level configuration (Part 1) is complete."
    exit 0
fi

echo "--> 3. Configuring Calico Manifest..."
# Clean up old files
rm -f calico.yaml
echo "    Downloading manifest..."
curl -O https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml

# Apply Configuration Patches
echo "    Patching manifest..."
# 1. Set Pod CIDR
sed -i "s|192.168.0.0/16|$POD_CIDR|g" calico.yaml
# 2. Set MTU to 1440 to prevent packet fragmentation drops
sed -i "s/veth_mtu: \".*\"/veth_mtu: \"$CALICO_MTU\"/g" calico.yaml
# 3. Inject Interface Detection Method (Lock to specific NIC)
sed -i '/- name: IP_AUTODETECTION_METHOD/,/value:.*$/d' calico.yaml
sed -i "/- name: CALICO_IPV4POOL_IPIP/i\\            - name: IP_AUTODETECTION_METHOD\\n              value: \"${IP_AUTODETECTION_METHOD}\"" calico.yaml
# 4. Force "Always" IPIP Mode
sed -i 's/name: CALICO_IPV4POOL_IPIP.*/name: CALICO_IPV4POOL_IPIP/g' calico.yaml
sed -i "s/value: \"Always\"/value: \"${CALICO_IPV4POOL_IPIP}\"/g" calico.yaml
sed -i "s/value: \"CrossSubnet\"/value: \"${CALICO_IPV4POOL_IPIP}\"/g" calico.yaml

echo "--> Applying Calico Manifest..."
kubectl apply -f calico.yaml

echo "--> 4. Applying FelixConfiguration (The 'Trust' Fix)..."
# This configures the Calico agent (Felix) to trust traffic from the interconnect subnet.
# 'workloadSourceSpoofing: Any' solves issues where Pod IPs seem to come from the wrong interface.
cat <<EOF | kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: FelixConfiguration
metadata:
  name: default
spec:
  bpfConnectTimeLoadBalancing: TCP
  bpfHostNetworkedNATWithoutCTLB: Enabled
  logSeverityScreen: Info
  reportingInterval: 0s
  workloadSourceSpoofing: Any
  # [CRITICAL] Trust the entire interconnect subnet for IPIP traffic
  externalNodesList: ["${INTERCONNECT_CIDR}"]
  failsafeInboundHostPorts:
  - protocol: "tcp"
    port: 22
  - protocol: "tcp"
    port: 10250
  - protocol: "tcp"
    port: 179
EOF

echo "--> Restarting Calico to apply changes..."
kubectl rollout restart ds calico-node -n kube-system

echo "======================================================="
echo "SETUP COMPLETE."
echo "IMPORTANT: Please ensure PART 1 (System Config) is run on ALL nodes."
echo "======================================================="