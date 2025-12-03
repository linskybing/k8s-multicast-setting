#!/bin/bash
set -e

echo "=== 1. System Tuning & Prerequisites ==="

# 1.1 Disable swap (Required for K8s)
echo "Disabling swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 1.2 Sysctl Tuning (Networking & File Limits)
echo "Applying sysctl tuning..."
cat <<EOF | sudo tee /etc/sysctl.d/99-k8s-worker.conf
# Kubernetes Networking
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# Increase inotify limits (Critical for Logs/Longhorn)
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192

# Increase maximum number of open files
fs.file-max = 100000
EOF

# Load modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
sudo sysctl --system

echo "=== 2. Installing Container Runtime (containerd) ==="
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd

# Configure containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
# Set SystemdCgroup to true
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "=== 3. Installing Kubernetes Binaries ==="
# 3.1 Add K8s Repo (v1.29)
sudo mkdir -p -m 755 /etc/apt/keyrings
if [ -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
    sudo rm /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# 3.2 Install kubelet, kubeadm, kubectl
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

echo "----------------------------------------------------------------"
echo "Worker Node Prerequisites Installed!"
echo "Next Steps:"
echo "1. If this node has a GPU, run './01-install-gpu-worker.sh'"
echo "2. Run the join command provided by the master node."
echo "----------------------------------------------------------------"
