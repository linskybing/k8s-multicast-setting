#!/bin/bash
set -e

# ==============================================================================
# Production Monitoring Setup: GPU + K8s
# Scope:
# 1. Configures Grafana (Public Access, Persistence)
# 2. Installs NVIDIA DCGM Exporter (The Metric Source)
# 3. Creates ServiceMonitor ( The Bridge for Prometheus to scrape GPU metrics)
# 4. Installs Production Dashboards (GPU, Namespace, Compute)
# ==============================================================================

# NodePort for external access
GRAFANA_PORT=30003

echo "=== Starting Complete Monitoring Stack Configuration ==="

# ------------------------------------------------------------------------------
# 1. Update Grafana Configuration (Helm)
# ------------------------------------------------------------------------------
echo "[STEP 1] Updating Grafana Settings..."

# We use --reuse-values to preserve existing Prometheus/AlertManager settings
# while strictly enforcing Grafana's persistence and access policies.
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --reuse-values \
  --set grafana.service.nodePort=$GRAFANA_PORT \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.storageClass=longhorn \
  --set grafana.grafana\.ini.auth\.anonymous.enabled=true \
  --set grafana.grafana\.ini.auth\.anonymous.org_role=Viewer \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=longhorn

echo "[INFO] Waiting for Grafana to reload settings..."
kubectl rollout status deployment kube-prometheus-stack-grafana -n monitoring --timeout=120s

# ------------------------------------------------------------------------------
# 2. Install NVIDIA DCGM Exporter
# ------------------------------------------------------------------------------
echo "[STEP 2] Ensuring NVIDIA DCGM Exporter is installed..."
# This pod runs on the GPU node and exposes metrics on port 9400
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/dcgm-exporter/main/dcgm-exporter.yaml

# ------------------------------------------------------------------------------
# 3. Create ServiceMonitor (CRITICAL FIX for 'No Data')
# ------------------------------------------------------------------------------
echo "[STEP 3] Creating ServiceMonitor for Prometheus..."
# Without this, Prometheus does not know how to scrape the DCGM exporter.

cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dcgm-exporter
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: dcgm-exporter
  # Scan all namespaces because dcgm-exporter usually runs in 'default' or 'kube-system'
  namespaceSelector:
    any: true
  endpoints:
  - port: metrics
    interval: 15s
    path: /metrics
EOF

echo "[INFO] ServiceMonitor applied. Prometheus will pick up GPU metrics within 30 seconds."

# ------------------------------------------------------------------------------
# 4. Install Dashboards (Infrastructure as Code)
# ------------------------------------------------------------------------------
echo "[STEP 4] Installing Production Dashboards..."

# Function to download, fix datasource, and install dashboards via ConfigMap
install_dashboard() {
    local ID=$1
    local NAME=$2
    local FILE="/tmp/${NAME}.json"
    
    echo "[INFO] Processing Dashboard: $NAME (ID: $ID)..."
    
    # 1. Download JSON from Grafana.com
    curl -sL -o "$FILE" "https://grafana.com/api/dashboards/${ID}/revisions/latest/download"
    
    # 2. Fix Datasource Variables
    # Many community dashboards use hardcoded or variable datasource names that cause "No Data" errors.
    # We force them to use the default "Prometheus" datasource.
    sed -i 's/"datasource": *"[^"]*"/"datasource": "Prometheus"/g' "$FILE"
    sed -i 's/${DS_PROMETHEUS}/Prometheus/g' "$FILE"

    # 3. Create ConfigMap with "grafana_dashboard=1" label
    # The Grafana sidecar automatically detects this label and imports the dashboard.
    kubectl create configmap "grafana-dashboard-${NAME}" \
      --namespace monitoring \
      --from-file="${NAME}.json=${FILE}" \
      --dry-run=client -o yaml | \
      kubectl label --local -f - grafana_dashboard=1 -o yaml | \
      kubectl apply -f -
      
    rm "$FILE"
}

# --- Dashboard List ---

# 1. NVIDIA DCGM Exporter (GPU Metrics)
# Shows Temperature, Power Usage, Memory, and Utilization per GPU
install_dashboard 12239 "nvidia-gpu"

# 2. K8s / Views / Namespaces
# High-level overview of all namespaces
install_dashboard 15758 "ns-view"

# 3. K8s / Compute Resources / Namespace
# Detailed CPU/Memory breakdown by Pod/Workload
install_dashboard 15761 "ns-compute"

# 4. Kubernetes Cluster (Top Pods)
# Ranking of most resource-intensive pods
install_dashboard 6417 "cluster-top"

# ------------------------------------------------------------------------------
# Summary Output
# ------------------------------------------------------------------------------
# Get Node IP for display
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "========================================================"
echo "   Dashboard & GPU Monitoring Setup Complete"
echo "========================================================"
echo "Grafana Access:"
echo "   URL: http://$NODE_IP:$GRAFANA_PORT"
echo "   Auth: Anonymous (No login required)"
echo ""
echo "Direct Links:"
echo "   [GPU] NVIDIA Metrics:"
echo "   http://$NODE_IP:$GRAFANA_PORT/d/nvidia-gpu?orgId=1&refresh=5s"
echo ""
echo "   [K8s] Namespace Overview:"
echo "   http://$NODE_IP:$GRAFANA_PORT/d/k8s-views-namespaces?orgId=1&refresh=10s"
echo ""
echo "   [K8s] Workload Resources:"
echo "   http://$NODE_IP:$GRAFANA_PORT/d/k8s-resources-namespace?orgId=1&refresh=10s"
echo "========================================================"