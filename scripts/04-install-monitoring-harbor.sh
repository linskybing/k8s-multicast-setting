#!/bin/bash
set -e
set -o pipefail

# --- 1. Global Configuration ---
DATA_PATH="/data"
HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD:-"Harbor12345"}
GRAFANA_PORT=30003
HARBOR_PORT=30002

# Color Definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
err() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

echo "========================================================"
echo "   Production Cluster Deployment (Robust Version)       "
echo "========================================================"

# --- 2. Pre-flight Checks ---
log "Step 0: Checking Environment..."

if [ ! -d "$DATA_PATH" ]; then
    err "Directory $DATA_PATH does not exist. Please mount your drive properly."
fi

log "Checking CNI/Network health..."
if kubectl get pods -n kube-system | grep -v "Running" | grep -q "kube-flannel\|calico\|coredns"; then
    warn "Some network pods in kube-system are not running. Attempting to proceed, but this is risky."
    kubectl get pods -n kube-system
    sleep 5
else
    log "CNI Network looks healthy."
fi

if ! command -v helm &> /dev/null; then
    log "Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- 3. Install System Dependencies ---
log "Step 1: Installing System Dependencies (iSCSI, NFS)..."
sudo apt-get update -qq > /dev/null
sudo apt-get install -y open-iscsi nfs-common util-linux grep jq > /dev/null
sudo systemctl enable --now iscsid

# --- 4. Configure Helm Repositories ---
log "Step 2: Configuring Helm Repositories..."
helm repo add longhorn https://charts.longhorn.io 2>/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null
helm repo add harbor https://helm.goharbor.io 2>/dev/null
helm repo update > /dev/null

# --- 5. Deploy Longhorn ---
log "Step 3: Deploying Longhorn..."

kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -

# Cleanup phantom releases
if helm status longhorn -n longhorn-system >/dev/null 2>&1; then
    log "Longhorn release found. Attempting upgrade..."
else
    warn "Cleaning up old secrets to force fresh install..."
    kubectl -n longhorn-system delete secret -l owner=helm,name=longhorn --ignore-not-found
fi

# Calculate Node Count
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
SOFT_AFFINITY="false"
if [ "$NODE_COUNT" -lt 3 ]; then
    SOFT_AFFINITY="true"
    warn "Node count is $NODE_COUNT (< 3). Installing with Soft Anti-Affinity ENABLED."
fi

# Install Command (Wait Disabled)
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set defaultSettings.createDefaultDiskLabeledNodes=true \
  --set defaultSettings.defaultDataPath="$DATA_PATH" \
  --set persistence.defaultClassReplicaCount=1 \
  --set persistence.defaultClass=true \
  --set defaultSettings.replicaNodeLevelSoftAntiAffinity=$SOFT_AFFINITY

# --- 6. Wait for Longhorn Initialization ---
log "Step 4: Waiting for Longhorn Initialization..."

# Wait for CRDs
kubectl wait --for=condition=established crd/settings.longhorn.io --timeout=300s >/dev/null 2>&1 || true

# Wait for Manager Pods
kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=300s

log "Longhorn Manager is ready. Waiting for API to stabilize..."
sleep 10

# --- 7. Apply Advanced Settings (Robust Retry Logic) ---
log "Step 5: Applying Longhorn Tuning..."
# Ensure all nodes are labeled
kubectl get nodes -o name | xargs -I {} kubectl label {} node.longhorn.io/create-default-disk=true --overwrite 2>/dev/null || true

# Verify StorageClass
log "Verifying Storage Class..."
if ! kubectl get sc longhorn >/dev/null 2>&1; then
    err "StorageClass 'longhorn' not found. Installation failed."
fi

# --- 8. Deploy Monitoring ---
log "Step 6: Deploying Monitoring Stack..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=$GRAFANA_PORT \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.storageClass=longhorn \
  --set grafana.persistence.size=10Gi \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=longhorn \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi

# --- 9. Deploy Harbor ---
log "Step 7: Deploying Harbor Registry..."
kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -

EXT_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

helm upgrade --install harbor harbor/harbor \
  --namespace harbor \
  --set harborAdminPassword="$HARBOR_ADMIN_PASSWORD" \
  --set expose.type=nodePort \
  --set expose.tls.enabled=false \
  --set expose.tls.auto.commonName=$EXT_IP \
  --set externalURL="http://$EXT_IP:$HARBOR_PORT" \
  --set persistence.persistentVolumeClaim.registry.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.registry.size=100Gi \
  --set persistence.persistentVolumeClaim.registry.accessMode=ReadWriteOnce \
  --set persistence.persistentVolumeClaim.jobservice.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.database.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.redis.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.trivy.storageClass=longhorn

# --- 10. Summary ---
echo "========================================================"
log "Deployment Completed Successfully!"
echo "========================================================"
echo -e "   Harbor:   http://$EXT_IP:$HARBOR_PORT"
echo -e "   Grafana:  http://$EXT_IP:$GRAFANA_PORT"
echo -e "   Longhorn: (Access via Port Forward or NodePort if configured)"
echo "--------------------------------------------------------"
if [ "$SOFT_AFFINITY" == "true" ]; then
    warn "Notice: Soft Anti-Affinity is ENABLED (Single Node Mode)."
    echo "When you add more nodes (Total >= 3), run the following to enforce HA:"
    echo "kubectl patch -n longhorn-system setting replica-node-level-soft-anti-affinity --type=merge -p '{\"value\": \"false\"}'"
fi
echo "========================================================"