#!/bin/bash

# Kubernetes Node Reset Script (Optimized for Multus/Macvlan)
echo "WARNING: This script will reset K8s, Multus CNI, and clear local IPAM records."
read -p "Are you sure you want to continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation aborted."
    exit 1
fi

# 1. Stop Kubelet to release locks
echo ">>> 1. Stopping Kubelet service..."
sudo systemctl stop kubelet

# 2. Official kubeadm reset
echo ">>> 2. Running kubeadm reset..."
sudo kubeadm reset --force

# 3. Network Cleanup (CRITICAL for Multus/Macvlan)
echo ">>> 3. Cleaning up CNI networking..."

# Remove CNI configs (including Multus auto-generated files)
sudo rm -rf /etc/cni/net.d

# [IMPORTANT] Clean up 'host-local' IPAM data
# Your script uses "type": "host-local". It stores allocated IPs on disk.
# If not cleared, re-installation will fail due to "IP exhaustion".
echo "    -> Clearing host-local IPAM data..."
sudo rm -rf /var/lib/cni/networks

# Clean up CNI binaries (Optional, but good for a fresh Multus install)
# sudo rm -rf /opt/cni/bin/multus

# Clean up legacy CNI interfaces (cni0/flannel) if used as the "default" network
# Multus usually wraps another CNI. We clean these just in case.
sudo ip link delete cni0 2>/dev/null
sudo ip link delete flannel.1 2>/dev/null
sudo ip link delete kube-ipvs0 2>/dev/null

# Flush iptables to remove old forwarding rules
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# 4. Clean up directories (Safe cleanup)
echo ">>> 4. Removing Kubernetes files..."
# Unmount explicitly if active mounts exist
mount | grep '/var/lib/kubelet' | awk '{print $3}' | xargs -r sudo umount

sudo rm -rf /etc/kubernetes/manifests
sudo rm -rf /var/lib/etcd
sudo rm -rf /var/lib/kubelet

# 5. User Config Backup
echo ">>> 5. Backing up user config..."
if [ -d "$HOME/.kube" ]; then
    BACKUP_NAME="$HOME/.kube_backup_$(date +%Y%m%d_%H%M%S)"
    mv "$HOME/.kube" "$BACKUP_NAME"
    echo "Backed up to: $BACKUP_NAME"
fi

# 6. Finalize
echo ">>> 6. Reloading systemd..."
sudo systemctl daemon-reload

echo "-------------------------------------------------------"
echo "Reset complete."
echo "NOTE: Since you use Multus, ensure you re-apply the 'NetworkAttachmentDefinition'"
echo "      after the cluster is back up, as CRDs are stored in Etcd."