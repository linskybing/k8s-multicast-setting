#!/bin/bash
# 腳本用途：徹底清除 Kubernetes, CNI, Etcd 與殘留進程
# 使用方式：sudo ./reset-cluster.sh

# 確保以 root 執行
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Please run as root."
  exit 1
fi

echo ">>> 1. Stopping Kubernetes Services..."
systemctl stop kubelet
systemctl stop containerd

echo ">>> 2. Killing Processes & Clearing Ports..."

PORTS=(6443 2379 2380 10250 10257 10259)
for port in "${PORTS[@]}"; do
    fuser -k -n tcp "$port" >/dev/null 2>&1 || true
done

killall -9 kubelet kube-proxy kube-apiserver kube-controller-manager kube-scheduler etcd containerd-shim-runc-v2 >/dev/null 2>&1 || true

echo ">>> 3. Force Unmounting (Prevent Hangs)..."
mount | grep '/var/lib/kubelet' | awk '{print $3}' | xargs -r umount -l
mount | grep '/var/lib/cni' | awk '{print $3}' | xargs -r umount -l

echo ">>> 4. Running kubeadm reset..."
kubeadm reset --force --cleanup-tmp-dir || true

echo ">>> 5. Cleaning Network Artifacts..."
rm -rf /etc/cni/net.d
rm -rf /var/lib/cni/networks
rm -rf /var/lib/cni/results

ip link delete cni0 >/dev/null 2>&1 || true
ip link delete flannel.1 >/dev/null 2>&1 || true
ip link delete kube-ipvs0 >/dev/null 2>&1 || true
ip link delete net1 >/dev/null 2>&1 || true # Macvlan

iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X || true

echo ">>> 6. Removing Cluster Files..."
rm -rf /etc/kubernetes
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd
rm -rf /root/.kube
rm -rf /home/*/.kube

echo ">>> 7. Restarting Container Runtime..."
systemctl start containerd

echo "-------------------------------------------------------"
echo "[SUCCESS] Cluster reset complete."
echo "Ports 6443/2379/2380 are now free."
echo "You can now run './install_k8s_fixed.sh'."
echo "-------------------------------------------------------"