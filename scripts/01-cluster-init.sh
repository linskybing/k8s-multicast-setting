#!/bin/bash
set -e

# ================= CONFIGURATION =================
# [CRITICAL] Use 10.244.x.x for internal Pods to avoid conflict 
# with your physical network (192.168.1.x) used by Macvlan.
POD_CIDR="10.244.0.0/16"
K8S_VERSION="1.29"
# =================================================

echo "=== 1. System Prep: Swap & Kernel Modules ==="
# Disable swap (Kubernetes will not work with swap enabled)
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load kernel modules required by CNI
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Apply Sysctl params (Networking)
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "=== 2. Install Container Runtime (containerd) ==="
# Use Docker's official repo for a stable, production-ready containerd
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

# Add Docker GPG key
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

# Configure containerd to use SystemdCgroup (Critical for K8s stability)
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

echo "=== 3. Install Kubernetes Components (v${K8S_VERSION}) ==="
# Add Kubernetes GPG key and Repo
sudo mkdir -p -m 755 /etc/apt/keyrings
[ -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ] && sudo rm /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
# Lock versions to prevent accidental upgrades
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

echo "=== 4. Initialize Cluster ==="
# [CRITICAL] Init with specific CIDR and CRI socket
sudo kubeadm init --pod-network-cidr=$POD_CIDR --cri-socket unix:///var/run/containerd/containerd.sock

# Setup kubeconfig for current user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "=== 5. Install Primary CNI (Calico) ==="
# Download Calico manifest
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# [CRITICAL] Patch Calico to use our custom POD_CIDR (10.244.0.0/16)
# Default Calico uses 192.168.0.0/16 which conflicts with your Macvlan setup.
echo "Patching Calico CIDR to $POD_CIDR..."
sed -i "s|192.168.0.0/16|$POD_CIDR|g" calico.yaml

kubectl apply -f calico.yaml

echo "=== 6. Post-Install (Optional) ==="
# Untaint master to allow Pods to run on this node (for single-node clusters)
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || echo "Note: Taint already removed or not found."

echo "-------------------------------------------------------"
echo "K8s Installation Complete!"
echo "Next Step: Run your Multus/Macvlan script."