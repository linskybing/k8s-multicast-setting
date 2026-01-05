#!/bin/bash
set -e

# ==============================================================================
# SCRIPT: Production Monitoring Stack Setup (Grafana + Prometheus)
# SCOPE:  Installs Monitoring only. Assumes GPU Drivers & Plugin are already set.
# ==============================================================================

# --- Configuration Variables ---
GRAFANA_PORT=30003                       # External NodePort for Grafana
STORAGE_CLASS="longhorn"                 # Storage class for persistence
NAMESPACE="monitoring"

echo "========================================================"
echo "      STARTING K8S MONITORING STACK DEPLOYMENT          "
echo "========================================================"

# ------------------------------------------------------------------------------
# SECTION 1: Prerequisites & Helm Setup
# ------------------------------------------------------------------------------
echo "[STEP 1] Checking Helm installation..."
if ! command -v helm &> /dev/null; then
    echo "Helm not found. Installing..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "[STEP 2] Adding Prometheus Community Repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# ------------------------------------------------------------------------------
# SECTION 2: Deploy Prometheus & Grafana (With Auth Fix)
# ------------------------------------------------------------------------------
echo "[STEP 3] Configuring and Deploying Kube-Prometheus-Stack..."

# Create a temporary values file to correctly handle Grafana config structure.
# This ensures Anonymous Auth works and persistence is enabled.
cat <<EOF > /tmp/monitoring-values.yaml
grafana:
  service:
    type: NodePort
    nodePort: $GRAFANA_PORT
  persistence:
    enabled: true
    storageClass: $STORAGE_CLASS
    size: 10Gi
  # Security: Enable Anonymous Access (No Login Required)
  grafana.ini:
    auth.anonymous:
      enabled: true
      org_role: Viewer
      org_name: Main Org.
    auth:
      disable_login_form: false
prometheus:
  prometheusSpec:
    # ServiceMonitorSelectorNilUsesHelmValues: false allows Prom to find custom ServiceMonitors
    serviceMonitorSelectorNilUsesHelmValues: false
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: $STORAGE_CLASS
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
EOF

# Deploy using Helm
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace $NAMESPACE \
  --create-namespace \
  -f /tmp/monitoring-values.yaml \
  --wait

echo "[INFO] Monitoring Stack Deployed. Restarting Grafana to ensure config load..."
# Force restart to guarantee the grafana.ini changes take effect
kubectl rollout restart deployment kube-prometheus-stack-grafana -n $NAMESPACE
kubectl rollout status deployment kube-prometheus-stack-grafana -n $NAMESPACE --timeout=120s

# ------------------------------------------------------------------------------
# SECTION 3: GPU Metrics Export (DCGM Exporter)
# ------------------------------------------------------------------------------
echo "[STEP 4] Deploying NVIDIA DCGM Exporter..."
# This Pod collects metrics from the GPU. It requires the GPU drivers to be already working.
kubectl apply -f ../manifests/gpu/gpu-exporter.yaml -n $NAMESPACE

echo "[STEP 5] Creating ServiceMonitor..."
# This tells Prometheus "Where" to find the GPU metrics.
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dcgm-exporter
  namespace: $NAMESPACE
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: dcgm-exporter
  namespaceSelector:
    any: true
  endpoints:
  - port: metrics
    interval: 15s
    path: /metrics
EOF

# ------------------------------------------------------------------------------
# SECTION 4: Importing Production Dashboards
# ------------------------------------------------------------------------------
echo "[STEP 6] Downloading and Importing Dashboards..."

# Function to download dashboard JSON, fix datasource, and apply as ConfigMap
install_dashboard() {
    local ID=$1
    local NAME=$2
    local FILE="/tmp/${NAME}.json"
    
    echo " -> Processing Dashboard: $NAME (ID: $ID)..."
    
    # Download
    curl -sL -o "$FILE" "https://grafana.com/api/dashboards/${ID}/revisions/latest/download"
    
    # Patch Datasource to "Prometheus" (Fixes "No Data" issues)
    sed -i 's/"datasource": *"[^"]*"/"datasource": "Prometheus"/g' "$FILE"
    sed -i 's/${DS_PROMETHEUS}/Prometheus/g' "$FILE"

    # Create ConfigMap with label "grafana_dashboard=1" (Sidecar auto-import)
    kubectl create configmap "grafana-dashboard-${NAME}" \
      --namespace $NAMESPACE \
      --from-file="${NAME}.json=${FILE}" \
      --dry-run=client -o yaml | \
      kubectl label --local -f - grafana_dashboard=1 -o yaml | \
      kubectl apply -f -
      
    rm "$FILE"
}

# 1. NVIDIA GPU Metrics (Temp, Power, Memory)
install_dashboard 12239 "nvidia-gpu"
# 2. Namespace Overview
install_dashboard 15758 "ns-view"
# 3. Compute Resources (Pod CPU/RAM)
install_dashboard 15761 "ns-compute"
# 4. Cluster Top Pods
install_dashboard 6417  "cluster-top"

# ------------------------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------------------------
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo ""
echo "========================================================"
echo "      MONITORING SETUP COMPLETE"
echo "========================================================"
echo "Grafana Access (Anonymous Mode):"
echo "   URL: http://$NODE_IP:$GRAFANA_PORT"
echo ""
echo "Direct Dashboard Links:"
echo "   [GPU] NVIDIA Metrics:"
echo "   http://$NODE_IP:$GRAFANA_PORT/d/nvidia-gpu?orgId=1&refresh=5s"
echo ""
echo "   [K8s] Namespace View:"
echo "   http://$NODE_IP:$GRAFANA_PORT/d/k8s-views-namespaces?orgId=1"
echo "========================================================"