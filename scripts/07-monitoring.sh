#!/bin/bash
set -e

# ========================================================
#   GLOBAL CONFIGURATION
# ========================================================
HARBOR_NAMESPACE="harbor"
MONITOR_NAMESPACE="monitoring"
# [NEW] Namespace for the Certificate Installer DaemonSet
INSTALLER_NAMESPACE="harbor-certs"

HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD:-"HarborProd123!"}

# NodePorts
HTTPS_NODE_PORT=30003
HTTP_NODE_PORT=30002
GRAFANA_PORT=30004

# Paths & Storage
CERTS_DIR="certs"
CERT_CONFIGMAP_PATH="/tmp/harbor-ca-configmap.yaml"
CERT_DAEMONSET_PATH="/tmp/harbor-ca-daemonset.yaml"
STORAGE_CLASS="nfs-client"

# Logging Helpers
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] INFO:${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARN:${NC} $1"; }
step() { echo -e "${CYAN}--------------------------------------------------------\n[STEP] $1\n--------------------------------------------------------${NC}"; }

# ========================================================
#   START DEPLOYMENT
# ========================================================

step "1. Environment Detection"
# Detect the Internal IP of the node (Control Plane)
EXT_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
log "Detected Host IP: $EXT_IP"

# Check Helm
if ! command -v helm &> /dev/null; then
    log "Helm not found. Installing..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

step "2. Certificate Generation (Self-Signed)"
log "Generating SSL certificates in $CERTS_DIR..."
mkdir -p "$CERTS_DIR"

# Generate CA
openssl genrsa -out "$CERTS_DIR/ca.key" 4096
openssl req -x509 -new -nodes -sha512 -days 3650 \
 -subj "/C=TW/ST=Taipei/L=Taipei/O=GPU-Cluster/OU=IT/CN=$EXT_IP" \
 -key "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt"

# Generate Harbor Server Key
openssl genrsa -out "$CERTS_DIR/harbor.key" 4096
openssl req -new -key "$CERTS_DIR/harbor.key" -out "$CERTS_DIR/harbor.csr" \
  -subj "/C=TW/ST=Taipei/L=Taipei/O=GPU-Cluster/OU=IT/CN=$EXT_IP"

# V3 Extension for SAN
cat > "$CERTS_DIR/v3.ext" <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
IP.1 = $EXT_IP
EOF

# Sign the certificate
openssl x509 -req -in "$CERTS_DIR/harbor.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" -CAcreateserial \
 -out "$CERTS_DIR/harbor.crt" -days 3650 -sha512 -extfile "$CERTS_DIR/v3.ext"

log "Certificates generated successfully."

step "3. Kubernetes Secrets & Namespaces"
# Create all necessary namespaces
kubectl create namespace $HARBOR_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $MONITOR_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $INSTALLER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Harbor TLS Secret
kubectl -n $HARBOR_NAMESPACE delete secret harbor-https-secret --ignore-not-found
kubectl -n $HARBOR_NAMESPACE create secret tls harbor-https-secret \
  --key "$CERTS_DIR/harbor.key" \
  --cert "$CERTS_DIR/harbor.crt"
log "TLS Secret created in namespace: $HARBOR_NAMESPACE"

# Harbor Registry Secret (for image pull jobs)
log "Creating Harbor registry secret in default namespace..."
kubectl delete secret harbor-regcred -n default --ignore-not-found
kubectl create secret docker-registry harbor-regcred \
  --docker-server="$EXT_IP:$HTTPS_NODE_PORT" \
  --docker-username="admin" \
  --docker-password="$HARBOR_ADMIN_PASSWORD" \
  --docker-email="admin@example.com" \
  -n default
log "Registry secret created in namespace: default"

step "4. Distribute CA to All Nodes (DaemonSet)"
log "Injecting CA certificate into containerd trust store on all nodes..."
log "Target Namespace: $INSTALLER_NAMESPACE"

# Create ConfigMap with CA
cat > "$CERT_CONFIGMAP_PATH" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: harbor-ca-cert
  namespace: $INSTALLER_NAMESPACE
data:
  harbor.crt: |
$(sed 's/^/    /' "$CERTS_DIR/ca.crt")
EOF

# Create DaemonSet to install certs
cat > "$CERT_DAEMONSET_PATH" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: harbor-cert-installer
  namespace: $INSTALLER_NAMESPACE
spec:
  selector:
    matchLabels:
      app: harbor-cert-installer
  template:
    metadata:
      labels:
        app: harbor-cert-installer
    spec:
      hostPID: true
      hostNetwork: true
      initContainers:
      - name: install-cert
        image: alpine:latest
        securityContext:
          privileged: true
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -e
            apk add --no-cache util-linux >/dev/null
            
            # Paths
            CONFIG_TOML="/host/etc/containerd/config.toml"
            CERTS_DIR="/host/etc/containerd/certs.d/$EXT_IP:$HTTPS_NODE_PORT"
            
            # 1. Ensure containerd config uses certs.d
            if [ ! -f "\$CONFIG_TOML" ]; then
              mkdir -p /host/etc/containerd
              nsenter --mount=/proc/1/ns/mnt -- containerd config default > "\$CONFIG_TOML"
            fi
            
            if grep -q 'config_path = ""' "\$CONFIG_TOML"; then
              sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|g' "\$CONFIG_TOML"
            fi

            # 2. Write Certificate and hosts.toml
            mkdir -p "\$CERTS_DIR"
            cp /config/harbor.crt "\$CERTS_DIR/ca.crt"
            
            echo "Generating hosts.toml..."
            printf 'server = "https://$EXT_IP:$HTTPS_NODE_PORT"\n' > "\$CERTS_DIR/hosts.toml"
            printf '[host."https://$EXT_IP:$HTTPS_NODE_PORT"]\n' >> "\$CERTS_DIR/hosts.toml"
            printf '  capabilities = ["pull", "resolve", "push"]\n' >> "\$CERTS_DIR/hosts.toml"
            printf '  ca = "/etc/containerd/certs.d/$EXT_IP:$HTTPS_NODE_PORT/ca.crt"\n' >> "\$CERTS_DIR/hosts.toml"

            # 3. Restart Containerd
            echo "Restarting containerd..."
            nsenter --mount=/proc/1/ns/mnt -- systemctl restart containerd
        volumeMounts:
        - name: host-etc
          mountPath: /host/etc
        - name: cert-config
          mountPath: /config
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
      volumes:
      - name: host-etc
        hostPath:
          path: /etc
      - name: cert-config
        configMap:
          name: harbor-ca-cert
EOF

# Clean up old resources in default namespace if they exist (to be safe)
kubectl delete daemonset harbor-cert-installer -n default --ignore-not-found
kubectl delete configmap harbor-ca-cert -n default --ignore-not-found

# Apply new resources
kubectl apply -f "$CERT_CONFIGMAP_PATH"
kubectl apply -f "$CERT_DAEMONSET_PATH"

log "Waiting for certificate distribution..."
kubectl rollout status daemonset/harbor-cert-installer -n $INSTALLER_NAMESPACE --timeout=60s || warn "Check daemonset status."

step "5. Deploy Harbor Registry"
log "Upgrading/Installing Harbor..."
helm repo add harbor https://helm.goharbor.io 2>/dev/null
helm repo update > /dev/null

helm upgrade --install harbor harbor/harbor \
  --namespace $HARBOR_NAMESPACE \
  --set harborAdminPassword="$HARBOR_ADMIN_PASSWORD" \
  --set expose.type=nodePort \
  --set expose.tls.enabled=true \
  --set expose.tls.certSource=secret \
  --set expose.tls.secret.secretName=harbor-https-secret \
  --set expose.tls.nodePort=$HTTPS_NODE_PORT \
  --set expose.nodePort.httpNodePort=$HTTP_NODE_PORT \
  --set externalURL="https://$EXT_IP:$HTTPS_NODE_PORT" \
  --set persistence.persistentVolumeClaim.registry.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.registry.size=200Gi \
  --set persistence.persistentVolumeClaim.jobservice.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.database.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.redis.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.trivy.storageClass=$STORAGE_CLASS \
  --wait

step "6. Deploy Prometheus & Grafana (Monitoring Stack)"
log "Configuring Kube-Prometheus-Stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null
helm repo update > /dev/null

# Create a temporary values file for advanced Grafana configuration
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
  # Enable Sidecar for Auto-Importing Dashboards from ConfigMaps
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
prometheus:
  prometheusSpec:
    # Important for finding custom ServiceMonitors like DCGM
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
  --namespace $MONITOR_NAMESPACE \
  --create-namespace \
  -f /tmp/monitoring-values.yaml \
  --wait

log "Restarting Grafana to ensure config load..."
kubectl rollout restart deployment kube-prometheus-stack-grafana -n $MONITOR_NAMESPACE
kubectl rollout status deployment kube-prometheus-stack-grafana -n $MONITOR_NAMESPACE --timeout=120s

step "7. Deploy NVIDIA DCGM Exporter (GPU Metrics)"
log "Deploying NVIDIA DCGM Exporter via Helm (Fixed Version)..."
kubectl apply -f ../manifests/gpu/gpu-exporter.yaml

# (Optional) Manually apply ServiceMonitor if Helm chart one fails to register
log "Ensuring ServiceMonitor is active..."
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dcgm-exporter-manual
  namespace: $MONITOR_NAMESPACE
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: dcgm-exporter
  namespaceSelector:
    matchNames:
      - $MONITOR_NAMESPACE
  endpoints:
  - port: metrics
    interval: 15s
    path: /metrics
EOF

step "8. Import Dashboards"
# Function to download dashboard JSON, fix datasource, and apply as ConfigMap
install_dashboard() {
    local ID=$1
    local NAME=$2
    local FILE="/tmp/${NAME}.json"
    
    log "Processing Dashboard: $NAME (ID: $ID)..."
    
    # Download
    curl -sL -o "$FILE" "https://grafana.com/api/dashboards/${ID}/revisions/latest/download"
    
    # Patch Datasource to "Prometheus" (Fixes "No Data" issues)
    sed -i 's/"datasource": *"[^"]*"/"datasource": "Prometheus"/g' "$FILE"
    sed -i 's/${DS_PROMETHEUS}/Prometheus/g' "$FILE"

    # Create ConfigMap with label "grafana_dashboard=1" (Sidecar auto-import)
    kubectl create configmap "grafana-dashboard-${NAME}" \
      --namespace $MONITOR_NAMESPACE \
      --from-file="${NAME}.json=${FILE}" \
      --dry-run=client -o yaml | \
      kubectl label --local -f - grafana_dashboard=1 -o yaml | \
      kubectl apply -f -
      
    rm "$FILE"
}

# 1. NVIDIA GPU Metrics
install_dashboard 12239 "nvidia-gpu"
# 2. Namespace Overview
install_dashboard 15758 "ns-view"
# 3. Compute Resources
install_dashboard 15761 "ns-compute"
# 4. Cluster Top Pods
install_dashboard 6417  "cluster-top"

step "9. Final Summary"
echo "========================================================"
echo -e "${GREEN}   DEPLOYMENT COMPLETE! ${NC}"
echo "========================================================"
echo -e "1. Harbor Registry (HTTPS)"
echo -e "   URL:      https://$EXT_IP:$HTTPS_NODE_PORT"
echo -e "   User:     admin"
echo -e "   Password: $HARBOR_ADMIN_PASSWORD"
echo ""
echo -e "2. GPU Monitoring (Grafana)"
echo -e "   URL:      http://$EXT_IP:$GRAFANA_PORT"
echo -e "   Access:   Public (Anonymous Mode)"
echo ""
echo -e "3. Installer Status"
echo -e "   Namespace: $INSTALLER_NAMESPACE"
echo -e "   Note: You can safely delete this namespace later if no new nodes will be added."
echo "========================================================"