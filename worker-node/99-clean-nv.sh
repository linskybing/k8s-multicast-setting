#!/bin/bash
set -e

echo "=== [Phase 0] NVIDIA Driver & Toolkit Deep Clean ==="
echo "WARNING: This will remove ALL NVIDIA drivers, CUDA, and Container Toolkit."
echo "Your screen may flicker or switch to low resolution."
echo "-------------------------------------------------------"

# 1. Stop Services to release locks on GPU drivers
echo ">>> Stopping Kubernetes and Container services..."
sudo systemctl stop kubelet || true
sudo systemctl stop containerd || true
sudo systemctl stop docker || true

# 2. Uninstall NVIDIA Container Toolkit (and docker integration)
echo ">>> Removing NVIDIA Container Toolkit..."
sudo apt-get purge -y nvidia-container-toolkit nvidia-container-runtime nvidia-docker2
sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

# 3. Purge NVIDIA Drivers and CUDA
echo ">>> Purging NVIDIA Drivers and CUDA (This may take a while)..."
# Using wildcard to catch driver, utils, settings, compute, etc.
sudo apt-get purge -y '*nvidia*'
sudo apt-get purge -y '*cuda*'
sudo apt-get purge -y 'libnvidia-*'

# 4. Remove residual configurations and directories
echo ">>> Cleaning up residual files..."
sudo apt-get autoremove -y
sudo apt-get autoclean -y

# Remove specific config directories that might confuse the new install
sudo rm -rf /usr/local/cuda*
sudo rm -rf /etc/nvidia
sudo rm -rf /etc/cdi
sudo rm -rf /var/lib/nvidia-container

# 5. Revert Containerd config (Optional but recommended)
# We remove the config so the installer can generate a fresh one
if [ -f /etc/containerd/config.toml ]; then
    echo ">>> Backing up containerd config..."
    sudo mv /etc/containerd/config.toml /etc/containerd/config.toml.cleaned.bak
fi

# 6. Update Initramfs
# Critical: Removes the driver from the boot image
echo ">>> Updating initramfs..."
sudo update-initramfs -u

echo "-------------------------------------------------------"
echo ">>> Cleanup Complete."
echo "CRITICAL: You MUST REBOOT before running the installation script."
echo "Command: sudo reboot"
echo "-------------------------------------------------------"

sudo reboot