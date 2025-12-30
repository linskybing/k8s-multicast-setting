#!/bin/bash
set -e

echo "===Configuring Longhorn Storage Dependencies ==="

sudo apt-get update
sudo apt-get install -y open-iscsi nfs-common util-linux curl jq

sudo systemctl enable --now iscsid

if ! lsmod | grep -q iscsi; then
    echo "[INFO] Loading iscsi_tcp module..."
    sudo modprobe iscsi_tcp
    echo "iscsi_tcp" | sudo tee -a /etc/modules
fi

sudo mkdir -p /var/lib/kubelet/plugins_registry
sudo mkdir -p /var/lib/kubelet/plugins/kubernetes.io/csi

sudo systemctl restart iscsid
sudo systemctl restart kubelet

echo "-------------------------------------------------------"
echo "Fix Complete: Storage dependencies are ready."
echo "Please wait 2 minutes for Longhorn pods to recover."
echo "-------------------------------------------------------"