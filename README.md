# Kubernetes ROS2 Multicast & GPU Cluster

This project provides a complete setup for a Kubernetes cluster optimized for ROS2 applications requiring **Multicast** communication and **NVIDIA GPU** acceleration. It includes a full monitoring stack and a private registry.

## 🏗 Architecture Overview

### 1. Kubernetes Cluster
*   **Version**: v1.29 (Stable)
*   **Container Runtime**: containerd (with SystemdCgroup)
*   **OS**: Ubuntu 24.04 LTS (Noble)

### 2. Networking (CNI)
The cluster uses a dual-homed network setup via **Multus CNI**:

*   **Primary Network (Pod Network)**:
    *   **Plugin**: Calico
    *   **CIDR**: `192.168.0.0/16`
    *   **Purpose**: Control plane communication, API access, standard K8s networking.

*   **Secondary Network (Multicast)**:
    *   **Plugin**: Macvlan (Bridge Mode)
    *   **Master Interface**: `enp6s18` (Physical Interface)
    *   **Subnet**: `10.121.124.0/24`
    *   **Gateway**: `10.121.124.254`
    *   **IP Range**: `10.121.124.200` - `10.121.124.210`
    *   **Purpose**: High-performance, low-latency ROS2 DDS Multicast communication (Layer 2).

### 3. Storage (CSI)
*   **Provider**: **Longhorn** (v1.10.1)
*   **Storage Class**: `longhorn` (Default)
*   **Features**: Distributed block storage, snapshots, backups, high availability.
*   **Disk Management**: LVM-based dynamic resizing (`ubuntu-lv`).

### 4. GPU Acceleration
*   **Hardware**: NVIDIA GPU
*   **Driver**: NVIDIA Proprietary Driver (Auto-detected, e.g., 535)
*   **Runtime**: NVIDIA Container Toolkit
*   **Device Plugin**: NVIDIA K8s Device Plugin (v0.14.0)
*   **Feature**: **MPS (Multi-Process Service)** enabled for efficient GPU sharing among multiple ROS2 nodes.

### 5. Monitoring & Registry
*   **Prometheus Stack**: Full cluster monitoring (Node Exporter, Kube State Metrics).
*   **Grafana**: Visualization dashboards.
*   **DCGM Exporter**: Deep introspection of NVIDIA GPU metrics (Temperature, Power, Utilization, Memory).
*   **Harbor**: Private container registry backed by Longhorn storage.

---

## 📂 Project Structure

```
k8s-ros2-multicast/
├── manifests/
│   ├── cni/
│   │   └── macvlan-conf.yaml       # NetworkAttachmentDefinition for ROS2 Multicast
│   ├── gpu/
│   │   └── nvidia-device-plugin.yaml # NVIDIA Device Plugin DaemonSet
│   └── ros2-app/
│       ├── deployment.yaml         # ROS2 Talker/Listener Deployment
│       └── service.yaml            # ROS2 Service (Optional)
├── scripts/
│   ├── 00-sysctl-tuning.sh         # Tune System Limits (Inotify/OpenFiles)
│   ├── 01-cluster-init.sh          # Init K8s, Calico, Containerd
│   ├── 02-install-cni-multicast.sh # Install Multus & Macvlan Config
│   ├── 03-install-gpu-drivers.sh   # Install NVIDIA Drivers, MPS, Device Plugin
│   ├── 04-deploy-ros2-app.sh       # Deploy ROS2 Test App (Talker/Listener)
│   ├── 05-install-monitoring-harbor.sh # Install Helm, Longhorn, Prometheus, Harbor, DCGM
│   ├── 06-setup-public-dashboards.sh # Setup Public Grafana Dashboards (Namespace/Resources)
│   └── 99-resize-disk.sh           # Utility to expand LVM disk space
└── README.md
```

---

## 🚀 Deployment Guide

### Step 0: System Tuning (Prerequisite)
```bash
cd scripts
./00-sysctl-tuning.sh
```
*   Increases `fs.inotify.max_user_watches` and `fs.file-max`.
*   Prevents "Too many open files" errors with Longhorn/Prometheus.

### Step 1: Initialize Cluster
```bash
cd scripts
./01-cluster-init.sh
```

*   Sets up Kubeadm, Kubelet, Kubectl.
*   Installs Calico CNI.
*   Removes Control Plane Taint.

### Step 2: Setup Multicast Network
```bash
./02-install-cni-multicast.sh
```
*   Installs Multus CNI (Thick plugin).
*   Creates `macvlan-conf` NetworkAttachmentDefinition attached to `enp6s18`.

### Step 3: Setup GPU Support
```bash
./03-install-gpu-drivers.sh
```
*   Checks/Installs NVIDIA Drivers.
*   Enables Persistence Mode & MPS Daemon.
*   Deploys NVIDIA Device Plugin.
*   **Note**: May require a reboot if drivers were missing.

### Step 4: Install Storage & Monitoring
```bash
./05-install-monitoring-harbor.sh
```
*   Installs Helm.
*   Deploys **Longhorn** (Storage).
*   Deploys **Prometheus + Grafana** (Monitoring).
*   Deploys **DCGM Exporter** (GPU Metrics).
*   Deploys **Harbor** (Registry).

### Step 5: Deploy ROS2 Application
```bash
./04-deploy-ros2-app.sh
```
*   Deploys `ros2-talker` and `ros2-listener` pods.
*   Attaches them to the `macvlan-conf` network.
*   Verifies Multicast communication via logs.

### Step 6: Setup Public Dashboards
\`\`\`bash
./06-setup-public-dashboards.sh
\`\`\`
*   Enables anonymous access to Grafana (Public View).
*   Installs **Namespace Overview**, **Compute Resources**, and **Cluster Top Pods** dashboards.
*   Outputs direct links to monitor specific namespaces and identify resource hogs.

---

## 📊 Access Points

| Service | Access Method | URL / Command | Credentials |
| :--- | :--- | :--- | :--- |
| **Grafana** | NodePort | \`http://<NodeIP>:30003\` | **Public** (No Login) |
| **Harbor** | NodePort | \`http://<NodeIP>:30002\` | User: \`admin\`<br>Pass: \`Harbor12345\` |
| **Longhorn UI** | Port Forward | \`localhost:8000\` | N/A |

**Port Forward Commands (Optional):**
```bash
# Longhorn
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8000:80
```


## 🔧 Troubleshooting

*   **Pod Stuck in ContainerCreating**: Check disk space (`df -h`) or CNI errors (`kubectl describe pod`).
*   **Multicast Not Working**: Ensure `macvlan-conf.yaml` uses the correct physical interface (`master: enp6s18`).
*   **GPU Not Found**: Check `nvidia-smi` on host and `kubectl get nodes -o=custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu`.
