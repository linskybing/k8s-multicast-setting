#! /bin/bash

# --- 8. [UPDATE] GPU Monitoring & Dashboard Integration ---
log "Updating Monitoring Stack with NVIDIA GPU Support..."

# 1. Install NVIDIA DCGM Exporter (Connects GPU to Prometheus)
log "Deploying NVIDIA DCGM Exporter..."
helm repo add nvidia https://nvidia.github.io/dcgm-exporter 2>/dev/null
helm repo update > /dev/null
helm upgrade --install dcgm-exporter nvidia/dcgm-exporter \
  --namespace monitoring \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.interval="15s"

# 2. Create ConfigMap for Auto-Loading NVIDIA Dashboard (ID: 12239)
log "Injecting NVIDIA GPU Dashboard (ID: 12239)..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: gpu-dashboard-config
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  gpu-dashboard.json: |
    {
      "gnetId": 12239,
      "name": "NVIDIA GPU Monitoring",
      "revision": 1
    }
EOF

# 3. Upgrade Prometheus Stack with GPU configuration
log "Configuring Grafana with Sidecar..."
GRAFANA_PORT=${GRAFANA_PORT:-30004}
STORAGE_CLASS="nfs-client"

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=$GRAFANA_PORT \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.storageClass=$STORAGE_CLASS \
  --set grafana.sidecar.dashboards.enabled=true \
  --set grafana.sidecar.dashboards.label=grafana_dashboard \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana."grafana\.ini".auth\.anonymous.enabled=true \
  --set grafana."grafana\.ini".auth\.anonymous.org_name="Main Org." \
  --set grafana."grafana\.ini".auth\.anonymous.org_role="Viewer" \
  --wait

log "GPU Monitoring Update Complete!"
echo "Public Dashboard URL: http://$EXT_IP:$GRAFANA_PORT"