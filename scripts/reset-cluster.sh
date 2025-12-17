#!/bin/bash

# Gentle Kubernetes Node Reset Script (v3 - Force Etcd Cleanup)
echo "WARNING: This script will reset Kubernetes configuration on this node."
read -p "Are you sure you want to continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation aborted."
    exit 1
fi

echo ">>> 1. Running official kubeadm reset..."
sudo kubeadm reset -f

echo ">>> 2. Cleaning up CNI configuration files..."
sudo rm -rf /etc/cni/net.d

echo ">>> 3. Forcing release of busy directories..."
# Lazy unmount (-l) detaches the filesystem now, and cleans up references later.
# This is much safer than a hardware-level 'force' which can crash the system.
sudo umount -l /var/lib/etcd 2>/dev/null
sudo umount -l /var/lib/kubelet 2>/dev/null

# Small sleep to allow the kernel to update the file descriptors
sleep 2

echo ">>> 4. Cleaning up core Kubernetes directories..."
sudo rm -rf /etc/kubernetes/manifests
sudo rm -rf /var/lib/etcd
sudo rm -rf /var/lib/kubelet

echo ">>> 5. Handling user-level configuration (Backup)..."
if [ -d "$HOME/.kube" ]; then
    BACKUP_NAME="$HOME/.kube_backup_$(date +%Y%m%d_%H%M%S)"
    mv "$HOME/.kube" "$BACKUP_NAME"
    echo "Existing ~/.kube backed up to: $BACKUP_NAME"
fi

echo ">>> 6. Restarting Kubelet service..."
sudo systemctl restart kubelet

echo "-------------------------------------------------------"
echo "Reset complete! Etcd and Kubelet directories cleared."
echo "Host network connection preserved."