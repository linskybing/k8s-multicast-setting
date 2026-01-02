#!/bin/bash
set -e

# Check for root
if [ "$EUID" -ne 0 ]; then 
  echo "Error: Please run as root."
  exit 1
fi

echo ">>> Installing K8s Boot Guard..."

# ---------------------------------------------------------
# 1. Create the Cleanup Script
# ---------------------------------------------------------
echo "[1/3] Creating /usr/local/bin/k8s-boot-guard.sh..."

cat <<'EOF' > /usr/local/bin/k8s-boot-guard.sh
#!/bin/bash
set -e
LOGFILE="/var/log/k8s-boot-guard.log"

echo "$(date) - [START] Pre-boot cleanup..." > $LOGFILE

# 1. Disable Swap (Required for Kubelet)
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 2. Clean Multus CNI (Fixes CrashLoopBackOff)
rm -rf /run/multus/ /var/run/multus/
rm -f /etc/cni/net.d/00-multus.conf

# 3. Clean NVIDIA MPS (Fixes connection errors)
rm -rf /run/nvidia/mps/* /tmp/nvidia-mps/*

# 4. Ensure CNI dir exists
mkdir -p /etc/cni/net.d

echo "$(date) - [SUCCESS] Ready for Kubelet." >> $LOGFILE
EOF

chmod +x /usr/local/bin/k8s-boot-guard.sh

# ---------------------------------------------------------
# 2. Create Systemd Service
# ---------------------------------------------------------
echo "[2/3] Creating Systemd service..."

cat <<EOF > /etc/systemd/system/k8s-boot-guard.service
[Unit]
Description=K8s Boot Guard
After=network-online.target container-runtime.service
# Run BEFORE Kubelet to ensure clean env
Before=kubelet.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k8s-boot-guard.sh
RemainAfterExit=true
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------
# 3. Set Kubelet Dependencies & Enable
# ---------------------------------------------------------
echo "[3/3] configuring Kubelet dependencies and enabling service..."

# Ensure Kubelet waits for Docker/Containerd
mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF > /etc/systemd/system/kubelet.service.d/99-guard-dep.conf
[Unit]
After=containerd.service docker.service
EOF

systemctl daemon-reload
systemctl enable k8s-boot-guard.service

echo ">>> Installation Complete. The node is now protected."
echo ">>> You can test by running: sudo reboot"

# kubectl get pods -A | grep Unknown | awk '{print $2 " -n " $1}' | xargs -L1 -r kubectl delete pod --grace-period=0 --force