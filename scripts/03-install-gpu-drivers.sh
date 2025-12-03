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

# Enable NVIDIA Persistence Mode (Required for MPS)
echo "Enabling NVIDIA Persistence Mode..."
sudo nvidia-smi -pm 1 || echo "Warning: Failed to enable persistence mode. MPS might not work."

# Configure and Start NVIDIA MPS (Multi-Process Service)
echo "Configuring NVIDIA MPS..."
if ! systemctl is-active --quiet nvidia-mps; then
    # Create systemd service for MPS if it doesn't exist
    cat <<EOF | sudo tee /etc/systemd/system/nvidia-mps.service
[Unit]
Description=NVIDIA MPS Server
After=syslog.target network.target

[Service]
Type=forking
ExecStart=/usr/bin/nvidia-cuda-mps-control -d
ExecStop=/bin/echo quit | /usr/bin/nvidia-cuda-mps-control
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now nvidia-mps
    echo "NVIDIA MPS service started."
else
    echo "NVIDIA MPS service is already running."
fi

# Install NVIDIA Device Plugin for Kubernetes
echo "Deploying NVIDIA Device Plugin..."
# We use the local manifest which should be configured for our needs
if [ -f ../manifests/gpu/nvidia-device-plugin.yaml ]; then
    kubectl apply -f ../manifests/gpu/nvidia-device-plugin.yaml
else
    echo "Downloading official NVIDIA Device Plugin manifest..."
    mkdir -p ../manifests/gpu
    curl -fsSL https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.16.2/nvidia-device-plugin.yml -o ../manifests/gpu/nvidia-device-plugin.yaml
    kubectl apply -f ../manifests/gpu/nvidia-device-plugin.yaml
fi

echo "Waiting for device plugin to be ready..."
# The label might vary, usually it's app=nvidia-device-plugin-daemonset or name=nvidia-device-plugin-ds
# We'll just wait a bit and show status
sleep 10
kubectl get pods -n kube-system -l app=nvidia-device-plugin-daemonset
kubectl get nodes "-o=custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu"