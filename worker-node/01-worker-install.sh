#!/bin/bash
set -e

K8S_VERSION="1.35"
# Control-plane join parameters (export before running):
#   CONTROL_PLANE_ENDPOINT="10.0.0.10:6443"
#   JOIN_TOKEN="<kubeadm-token>"
#   DISCOVERY_HASH="sha256:<hash>"
#   NODE_NAME="$(hostname)" (optional override)
CONTROL_PLANE_ENDPOINT=${CONTROL_PLANE_ENDPOINT:-"192.168.109.1:6443"}
JOIN_TOKEN=${JOIN_TOKEN:-"hths2c.x8h34ahuhfqha8gp"}
DISCOVERY_HASH=${DISCOVERY_HASH:-"sha256:65ced94e2de0af20656bf2d1d68d567c8c3efdee3c88585fcaf8840ced41f10e"}
NODE_NAME=${NODE_NAME:-$(hostname)}

echo "=== [Phase 2] Installing Containerd & K8s v${K8S_VERSION} ==="

# 1. Setup Docker GPG key and Repository for containerd
sudo apt-get update && sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update && sudo apt-get install -y containerd.io

# 2. Configure containerd with SystemdCgroup
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# 3. Install Kubernetes components (kubelet, kubeadm, kubectl)
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# 4. (Optional) Join control-plane if join data provided
if [[ -n "$CONTROL_PLANE_ENDPOINT" && -n "$JOIN_TOKEN" && -n "$DISCOVERY_HASH" ]]; then
	echo ">>> Resetting any previous kubeadm state..."
	sudo kubeadm reset -f
	echo ">>> Joining control plane at $CONTROL_PLANE_ENDPOINT as $NODE_NAME ..."
	sudo kubeadm join "$CONTROL_PLANE_ENDPOINT" \
		--token "$JOIN_TOKEN" \
		--discovery-token-ca-cert-hash "$DISCOVERY_HASH" \
		--cri-socket unix:///run/containerd/containerd.sock \
		--node-name "$NODE_NAME"
	echo ">>> kubeadm join complete."
else
	echo "[INFO] Join data not provided. Export CONTROL_PLANE_ENDPOINT, JOIN_TOKEN, DISCOVERY_HASH to auto-join."
fi

echo ">>> Phase 2 Complete: Runtime and K8s components installed."