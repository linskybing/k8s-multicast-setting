#!/bin/bash
set -e

echo "=== Current Disk Usage ==="
df -h /

echo "=== LVM Status ==="
sudo vgs
sudo lvs

echo "=== Extending Logical Volume ==="
# Extend the logical volume to use all remaining free space in the volume group
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv

echo "=== Resizing Filesystem ==="
# Resize the filesystem to match the new logical volume size
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv

echo "=== New Disk Usage ==="
df -h /

echo "=== Restarting Kubelet to clear DiskPressure ==="
sudo systemctl restart kubelet

echo "Done! Disk has been resized."
