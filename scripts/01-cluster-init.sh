#!/bin/bash
set -e

# ================= CONFIGURATION =================
# [CRITICAL] Default Pod CIDR. Can be overridden by env var or first arg
# Use a /16 by default to avoid accidental overlap with common LAN subnets.
POD_CIDR=${POD_CIDR:-${1:-"10.244.0.0/16"}}
K8S_VERSION="1.32"
CALICO_VERSION="v3.31.3" 
# =================================================

echo "=== 1. System Prep: Swap & Kernel Modules ==="
# Disable swap
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Apply Sysctl params
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "=== 2. Install Container Runtime (containerd) ==="
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

# Add Docker GPG key (Fixed permissions)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker Repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y containerd.io

# Configure containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

echo "=== 3. Install Kubernetes Components (v${K8S_VERSION}) ==="
sudo mkdir -p -m 755 /etc/apt/keyrings
[ -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ] && sudo rm /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
# sudo apt-mark unhold kubelet kubeadm kubectl
echo "=== 4. Initialize Cluster ==="
# Check if cluster is already initialized to avoid error
if [ -f /etc/kubernetes/admin.conf ]; then
    echo "Cluster already initialized. Skipping kubeadm init."
else
  # Validate POD_CIDR format before init
  if ! python3 - <<PY
import ipaddress,sys
try:
  ipaddress.ip_network("$POD_CIDR")
except Exception as e:
  sys.exit(2)
PY
  then
    echo "[ERROR] POD_CIDR ($POD_CIDR) is not a valid CIDR."
    exit 1
  fi

  sudo kubeadm init --pod-network-cidr=$POD_CIDR --cri-socket unix:///var/run/containerd/containerd.sock
fi

# Setup kubeconfig for current user
rm -rf $HOME/.kube
mkdir -p $HOME/.kube
sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Setup kubeconfig for root (Fix for sudo usage)
sudo rm -rf /root/.kube
sudo mkdir -p /root/.kube
sudo cp -f /etc/kubernetes/admin.conf /root/.kube/config
sudo chmod 600 /root/.kube/config

echo "=== 5. Install Primary CNI (Calico) ==="

echo "--> Installing Calico binaries manually to /opt/cni/bin..."
sudo mkdir -p /opt/cni/bin
cd /tmp
curl -f -L -O https://github.com/projectcalico/calico/releases/download/${CALICO_VERSION}/release-${CALICO_VERSION}.tgz && tar -xzf release-${CALICO_VERSION}.tgz
sudo cp -f release-${CALICO_VERSION}/bin/cni/amd64/calico /opt/cni/bin/
sudo cp -f release-${CALICO_VERSION}/bin/cni/amd64/calico-ipam /opt/cni/bin/
sudo chmod +x /opt/cni/bin/calico /opt/cni/bin/calico-ipam
echo "--> Calico binaries installed."



cd /tmp
curl -L -O https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz

sudo tar -xzf cni-plugins-linux-amd64-v1.3.0.tgz -C /opt/cni/bin/

ls -la /opt/cni/bin/ | grep macvlan

# Download and Apply Manifest
cd $HOME
curl -O https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml

echo "Patching Calico CIDR to $POD_CIDR..."
sed -i "s|192.168.0.0/16|$POD_CIDR|g" calico.yaml

kubectl apply -f calico.yaml

echo "=== 6. Post-Install ==="
# Untaint master
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "-------------------------------------------------------"
echo "K8s Installation Complete!"
echo "Next Step: Run your Multus/Macvlan script."