#!/bin/bash
set -e

echo "=== Installing NVIDIA GPU Drivers & MPS for Worker Node ==="

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
    echo "GPU driver already installed."
else
    echo "GPU driver not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y build-essential dkms ubuntu-drivers-common pciutils

    if ! lspci | grep -i nvidia; then
        echo "WARNING: No NVIDIA GPU detected via lspci."
    fi

    echo "Detecting recommended NVIDIA driver..."
    RECOMMENDED_DRIVER=$(ubuntu-drivers devices | grep "recommended" | awk '{print $3}')
    
    if [ -z "$RECOMMENDED_DRIVER" ]; then
        RECOMMENDED_DRIVER="nvidia-driver-535"
    fi

    echo "Installing $RECOMMENDED_DRIVER..."
    sudo apt-get install -y "$RECOMMENDED_DRIVER"
    
    echo "Driver installed. A REBOOT IS REQUIRED."
    echo "Please reboot and run this script again to enable MPS."
    exit 0
fi

# Enable NVIDIA Persistence Mode
echo "Enabling NVIDIA Persistence Mode..."
sudo nvidia-smi -pm 1 || echo "Warning: Failed to enable persistence mode."

# Configure and Start NVIDIA MPS
echo "Configuring NVIDIA MPS..."
if ! systemctl is-active --quiet nvidia-mps; then
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

echo "----------------------------------------------------------------"
echo "GPU Setup Complete!"
echo "The NVIDIA Device Plugin will be automatically deployed by the DaemonSet"
echo "once this node joins the cluster."
echo "----------------------------------------------------------------"
