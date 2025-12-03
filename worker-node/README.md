# Worker Node Setup Guide

This folder contains scripts to prepare a new worker node to join the Kubernetes cluster.

## Setup Instructions

### Step 1: Install Prerequisites
Run this script on the **worker node** to install Containerd, Kubeadm, and tune system limits.
```bash
chmod +x 00-worker-prereqs.sh
./00-worker-prereqs.sh
```

### Step 2: Install GPU Drivers (Optional)
If the worker node has an NVIDIA GPU, run this script to install drivers and enable MPS.
```bash
chmod +x 01-install-gpu-worker.sh
./01-install-gpu-worker.sh
```
*Note: You may need to reboot after driver installation.*

### Step 3: Join the Cluster
1.  **On the Master Node**, run this command to get the join token:
    ```bash
    kubeadm token create --print-join-command
    ```
2.  **On the Worker Node**, paste and run the output command.
    *   Example: `kubeadm join 192.168.1.100:6443 --token abcdef... --discovery-token-ca-cert-hash sha256:12345...`

### Step 4: Verify
On the **Master Node**, check if the node is ready:
```bash
kubectl get nodes
```
