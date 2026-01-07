#!/bin/bash
set -e

# Nodes Configuration
NODES=("gpu1" "gpu2" "gpu3")
NFS_SERVER_NODE="gpu1"
# Preferred 25Gb Interconnect for Storage
INTERCONNECT_CIDR="192.168.110.0/24"
STORAGE_IFACE=${STORAGE_IFACE:-"enp193s0f0np0"}
# Default NFS Server IP on 25Gb (override with env or set to 'auto' to detect)
NFS_SERVER_IP=${NFS_SERVER_IP:-"192.168.110.1"}
EXPORT_PATH="/data/k8s-nfs"

# Interactive Password Prompt
if [ -z "$NODE_PASS" ]; then
    read -s -p "Enter password for nodes (used for SSH & sudo): " NODE_PASS
    echo ""
fi
export NODE_PASS

echo "====================================================="
echo "   SETTING UP NFS SERVER ON $NFS_SERVER_NODE"
echo "====================================================="

# 1. Install NFS Server on gpu1
setup_nfs_server() {
    echo ">> Configuring NFS Server on $NFS_SERVER_NODE..."
    
    CMD_CONTENT=$(cat <<EOF
set -e
echo "$NODE_PASS" | sudo -S -p '' apt-get update -qq
echo "$NODE_PASS" | sudo -S -p '' apt-get install -y nfs-kernel-server

echo "   - Creating export directory: $EXPORT_PATH"
echo "$NODE_PASS" | sudo -S -p '' mkdir -p $EXPORT_PATH
echo "$NODE_PASS" | sudo -S -p '' chown nobody:nogroup $EXPORT_PATH
echo "$NODE_PASS" | sudo -S -p '' chmod 777 $EXPORT_PATH

echo "   - Configuring /etc/exports"
# Backup existing
if [ ! -f /etc/exports.bak ]; then
    echo "$NODE_PASS" | sudo -S -p '' cp /etc/exports /etc/exports.bak
fi

    # CLEANUP: Remove lines starting with digits (previous script error caused password specific artifacts)
    echo "$NODE_PASS" | sudo -S -p '' bash -c "sed -i '/^[0-9]/d' /etc/exports"

    # Add export if not exists (restrict to Interconnect CIDR)
    if ! grep -q "$EXPORT_PATH" /etc/exports; then
        echo "$NODE_PASS" | sudo -S -p '' bash -c "echo '$EXPORT_PATH $INTERCONNECT_CIDR(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports"
    fi

echo "   - Restarting NFS Server"
echo "$NODE_PASS" | sudo -S -p '' exportfs -a
echo "$NODE_PASS" | sudo -S -p '' systemctl restart nfs-kernel-server
echo ">> NFS Server Ready"
EOF
)
    # Encode
    B64_CMD=$(echo "$CMD_CONTENT" | base64 -w0)
    
    if [ "$NFS_SERVER_NODE" == "$(hostname)" ]; then
        echo "$B64_CMD" | base64 -d | bash
    else
        sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t $NFS_SERVER_NODE "echo '$B64_CMD' | base64 -d | bash"
    fi
}

# 2. Install Client Packages on ALL nodes
setup_clients() {
    for NODE in "${NODES[@]}"; do
        echo ">> Installing NFS Client on $NODE..."
        CMD_CONTENT=$(cat <<EOF
set -e
echo "$NODE_PASS" | sudo -S -p '' apt-get update -qq
echo "$NODE_PASS" | sudo -S -p '' apt-get install -y nfs-common
EOF
)
        B64_CMD=$(echo "$CMD_CONTENT" | base64 -w0)
        
        if [ "$NODE" == "$(hostname)" ]; then
            echo "$B64_CMD" | base64 -d | bash
        else
            sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t $NODE "echo '$B64_CMD' | base64 -d | bash"
        fi
    done
}

# 2.5 Detect NFS Server IP on 25Gb iface when requested
detect_nfs_ip() {
    if [ "$NFS_SERVER_IP" = "auto" ]; then
        echo ">> Detecting NFS Server IP on iface $STORAGE_IFACE..."
        CMD_CONTENT=$(cat <<EOF
ip -4 -o addr show "$STORAGE_IFACE" | awk '{print \$4}' | cut -d/ -f1
EOF
)
        B64_CMD=$(echo "$CMD_CONTENT" | base64 -w0)
        if [ "$NFS_SERVER_NODE" == "$(hostname)" ]; then
            NFS_SERVER_IP=$(echo "$B64_CMD" | base64 -d | bash)
        else
            NFS_SERVER_IP=$(sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t $NFS_SERVER_NODE "echo '$B64_CMD' | base64 -d | bash" 2>/dev/null | tr -d '\r')
        fi
        echo ">> Detected NFS Server IP: $NFS_SERVER_IP"
    fi
}

# 3. Deploy Kubernetes NFS Provisioner
setup_k8s_provisioner() {
    echo ">> Deploying NFS Subdir External Provisioner..."
    
    helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ 2>/dev/null || true
    helm repo update >/dev/null

    helm upgrade --install nfs-client nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
        --namespace nfs-storage \
        --create-namespace \
        --set nfs.server=$NFS_SERVER_IP \
        --set nfs.path=$EXPORT_PATH \
        --set storageClass.name=nfs-client \
        --set storageClass.defaultClass=true \
        --set storageClass.allowVolumeExpansion=true

    echo ">> NFS Provisioner Installed."
}

# Execution
setup_nfs_server
setup_clients
detect_nfs_ip
setup_k8s_provisioner

echo "====================================================="
echo "   NFS SETUP COMPLETE"
echo "====================================================="
echo "StorageClass 'nfs-client' is now available and set as default."
