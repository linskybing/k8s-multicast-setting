#!/bin/bash
set -e

# Function to check if NVIDIA driver is loaded
check_gpu_driver() {
    if command -v nvidia-smi &> /dev/null; then
        echo "NVIDIA driver is detected."
        return 0
    else
        return 1
    fi
}

if check_gpu_driver; then
    echo "GPU driver already installed. Proceeding to device plugin installation."
else
    echo "GPU driver not found. Installing..."
    
    # Update the package list
    sudo apt-get update
    sudo apt-get install -y build-essential dkms ubuntu-drivers-common pciutils

    # Check for GPU
    if ! lspci | grep -i nvidia; then
        echo "WARNING: No NVIDIA GPU detected via lspci. Driver installation might fail or be useless."
    fi

    # Detect recommended driver
    echo "Detecting recommended NVIDIA driver..."
    RECOMMENDED_DRIVER=$(ubuntu-drivers devices | grep "recommended" | awk '{print $3}')
    
    if [ -z "$RECOMMENDED_DRIVER" ]; then
        echo "No recommended driver detected by ubuntu-drivers."
        echo "Checking if any nvidia-driver is already installed..."
        INSTALLED=$(dpkg -l | grep '^ii' | grep nvidia-driver | awk '{print $2}' | head -n 1)
        if [ -n "$INSTALLED" ]; then
            echo "Found installed driver: $INSTALLED"
            RECOMMENDED_DRIVER=$INSTALLED
        else
            echo "No driver found. Defaulting to nvidia-driver-535 (common stable)."
            RECOMMENDED_DRIVER="nvidia-driver-535"
        fi
    fi

    echo "Target driver: $RECOMMENDED_DRIVER"
    
    # Extract version number (e.g., nvidia-driver-535 -> 535)
    # Handle cases like 535-server or 535-open
    VERSION_NUM=$(echo "$RECOMMENDED_DRIVER" | grep -oP 'nvidia-driver-\K[0-9]+')
    
    if [ -n "$VERSION_NUM" ]; then
        UTILS_PKG="nvidia-utils-$VERSION_NUM"
        echo "Installing $RECOMMENDED_DRIVER and $UTILS_PKG..."
        sudo apt-get install -y "$RECOMMENDED_DRIVER" "$UTILS_PKG"
    else
        echo "Could not parse version number. Installing driver package only..."
        sudo apt-get install -y "$RECOMMENDED_DRIVER"
    fi

    echo "----------------------------------------------------------------"
    echo "NVIDIA driver installation process completed."
    echo "If 'nvidia-smi' is still not found, A SYSTEM REBOOT IS REQUIRED."
    echo "Please reboot (sudo reboot) and run this script again."
    echo "----------------------------------------------------------------"
    
    # Check if we can proceed without reboot (if driver was just missing utils)
    if check_gpu_driver; then
        echo "Driver detected successfully! Proceeding..."
    else
        exit 0
    fi
fi

# Install NVIDIA Container Toolkit if not present
if ! command -v nvidia-ctk &> /dev/null; then
    echo "Installing NVIDIA Container Toolkit..."
    ./install-nvidia-toolkit.sh
else
    echo "NVIDIA Container Toolkit already installed."
    # Ensure configuration is correct (default runtime = nvidia)
    if ! grep -q 'default_runtime_name = "nvidia"' /etc/containerd/config.toml; then
        echo "Updating containerd config to use nvidia runtime by default..."
        sudo sed -i 's/default_runtime_name = "runc"/default_runtime_name = "nvidia"/' /etc/containerd/config.toml
        sudo systemctl restart containerd
    fi
fi

# Enable NVIDIA Persistence Mode (Required for MPS)
echo "Enabling NVIDIA Persistence Mode..."
sudo nvidia-smi -pm 1 || echo "Warning: Failed to enable persistence mode. MPS might not work."

# Disable Host MPS (Managed by Helm Chart now)
echo "Disabling Host NVIDIA MPS (to avoid conflicts with K8s DaemonSet)..."
if systemctl is-active --quiet nvidia-mps; then
    sudo systemctl stop nvidia-mps
    sudo systemctl disable nvidia-mps
    echo "Host NVIDIA MPS service stopped and disabled."
fi

# Install Helm if not present
echo "=== Installing Helm ==="
if ! command -v helm &> /dev/null; then
    echo "Helm not found. Installing..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "Helm is already installed."
fi

# Install NVIDIA Device Plugin via Helm
echo "Deploying NVIDIA Device Plugin via Helm..."
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

# Ensure the values file exists
VALUES_FILE="../manifests/gpu/nvidia-device-plugin-values.yaml"
if [ ! -f "$VALUES_FILE" ]; then
    echo "Error: Values file $VALUES_FILE not found!"
    exit 1
fi

echo "Installing/Upgrading NVIDIA Device Plugin..."
helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --version 0.18.0 \
  -f "$VALUES_FILE" \
  --wait

echo "Waiting for device plugin to be ready..."
kubectl get pods -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin
kubectl get nodes "-o=custom-columns=NAME:.metadata.name,GPU_SHARED:.status.allocatable.nvidia\.com/gpu\.shared"
