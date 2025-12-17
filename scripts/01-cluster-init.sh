#!/bin/bash

# 1. Disable swap (Required for K8s)
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 2. Install necessary packages and container runtime (containerd)
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd

# 2.1 Configure containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
# Set SystemdCgroup to true
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# 2.2 Load kernel modules and set sysctl params required by Kubernetes
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# 3. Download the public signing key for the Kubernetes package repositories
# Note: Using v1.29 as a stable example.
sudo mkdir -p -m 755 /etc/apt/keyrings
# If the file exists, remove it to avoid overwrite prompt issues
if [ -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
    sudo rm /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# 4. Add the appropriate Kubernetes repository
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# 5. Update package index again
sudo apt-get update

# 6. Install kubelet, kubeadm, and kubectl
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# 7. Enable kubelet service
sudo systemctl enable --now kubelet

# 8. Initialize the Kubernetes cluster
# Note: If you have already run init, you might need 'sudo kubeadm reset' first
# Explicitly specify the cri-socket to avoid "found multiple CRI endpoints" error
sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --cri-socket unix:///var/run/containerd/containerd.sock

# 9. Set up kubeconfig for the regular user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 10. Install a pod network add-on (Calico)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# 11. Allow scheduling pods on the control-plane node
# Note: The taint name changed from 'master' to 'control-plane' in newer versions
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || echo "Taint not found or already removed"