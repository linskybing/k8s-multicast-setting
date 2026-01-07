#!/bin/bash
set -e

# ========================================================
#   GLOBAL CONFIGURATION
# ========================================================
HARBOR_NAMESPACE="harbor"
MONITOR_NAMESPACE="monitoring"
INSTALLER_NAMESPACE="harbor-certs"

HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD:-"HarborProd123!"}
STORAGE_HOSTNAME="gpu1-storage"

# === [NETWORK CONFIGURATION] ===
# 1. UI/Management IP (1Gbps) - For Browser Access
UI_IP="192.168.109.1"

# 2. Data/Storage IP (25Gbps) - For Docker Pull/Push
# We explicitly set this to .1 (Storage) instead of .101 (Interconnect)
DATA_IP="192.168.110.1"

# NodePorts
HTTPS_NODE_PORT=30003
HTTP_NODE_PORT=30002
GRAFANA_PORT=30004

# Paths & Storage
CERTS_DIR="certs"
CERT_CONFIGMAP_PATH="/tmp/harbor-ca-configmap.yaml"
CERT_DAEMONSET_PATH="/tmp/harbor-ca-daemonset.yaml"
STORAGE_CLASS="nfs-client"
DCGM_MANIFEST_PATH="../manifests/gpu/gpu-exporter.yaml"

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

step "1. Network Configuration Check"
log "Management Interface (UI):   $UI_IP"
log "Storage Interface (Data):    $DATA_IP"

# Sanity Check: Ensure DATA_IP belongs to the 25Gbps subnet (110.x)
if [[ "$DATA_IP" != "192.168.110."* ]]; then
    warn "Warning: DATA_IP ($DATA_IP) does not look like the 110.x subnet."
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi
fi

# Check Helm installation
if ! command -v helm &> /dev/null; then
    log "Helm not found. Installing..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

step "2. Certificate Generation (Multi-IP Support)"
log "Generating SSL certificates including BOTH UI and DATA IPs..."
mkdir -p "$CERTS_DIR"

# Generate CA Key and Certificate
openssl genrsa -out "$CERTS_DIR/ca.key" 4096
openssl req -x509 -new -nodes -sha512 -days 3650 \
 -subj "/C=TW/ST=Taipei/L=Taipei/O=GPU-Cluster/OU=IT/CN=Harbor-CA" \
 -key "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt"

# Generate Harbor Server Key and CSR
openssl genrsa -out "$CERTS_DIR/harbor.key" 4096
openssl req -new -key "$CERTS_DIR/harbor.key" -out "$CERTS_DIR/harbor.csr" \
  -subj "/C=TW/ST=Taipei/L=Taipei/O=GPU-Cluster/OU=IT/CN=$DATA_IP"

# V3 Extension for SAN (Subject Alternative Name)
# This is crucial: We add BOTH the UI IP and the Data IP to the certificate.
cat > "$CERTS_DIR/v3.ext" <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
IP.1 = $DATA_IP
IP.2 = $UI_IP
DNS.1 = $STORAGE_HOSTNAME
EOF

# Sign the Harbor Certificate using our CA
openssl x509 -req -in "$CERTS_DIR/harbor.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" -CAcreateserial \
 -out "$CERTS_DIR/harbor.crt" -days 3650 -sha512 -extfile "$CERTS_DIR/v3.ext"

log "Certificates generated. Valid for IPs: $DATA_IP and $UI_IP"

step "3. Kubernetes Secrets & Namespaces"
# Create namespaces if they don't exist
kubectl create namespace $HARBOR_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $MONITOR_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $INSTALLER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Create Harbor TLS Secret
kubectl -n $HARBOR_NAMESPACE delete secret harbor-https-secret --ignore-not-found
kubectl -n $HARBOR_NAMESPACE create secret tls harbor-https-secret \
  --key "$CERTS_DIR/harbor.key" \
  --cert "$CERTS_DIR/harbor.crt"

# Registry Secrets (Push secret to all namespaces)
REGISTRY_NAMESPACES="default harbor monitoring nfs-storage $(kubectl get ns -o jsonpath='{.items[*].metadata.name}')"
REGISTRY_NAMESPACES=$(echo "$REGISTRY_NAMESPACES" | tr ' ' '\n' | sort -u | tr '\n' ' ')

log "Creating Harbor registry secret in all namespaces..."
for NS in $REGISTRY_NAMESPACES; do
  kubectl delete secret harbor-regcred -n "$NS" --ignore-not-found >/dev/null 2>&1
  # CRITICAL: We set the Docker Server to DATA_IP ($DATA_IP)
  # This ensures Kubernetes nodes use the 25Gbps interface to pull images.
  kubectl create secret docker-registry harbor-regcred \
    --docker-server="$DATA_IP:$HTTPS_NODE_PORT" \
    --docker-username="admin" \
    --docker-password="$HARBOR_ADMIN_PASSWORD" \
    --docker-email="admin@example.com" \
    -n "$NS" >/dev/null 2>&1
done

step "4. Distribute CA to All Nodes (DaemonSet)"
log "Injecting CA certificate into containerd trust store on all nodes..."
log "Targeting Registry URL for Trust: https://$DATA_IP:$HTTPS_NODE_PORT"

# Create ConfigMap with CA Certificate
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

# Create DaemonSet (Installer)
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
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
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
            
            # Use DATA_IP (192.168.110.1) as the trusted endpoint.
            # This ensures nodes trust the 25GbE path.
            TARGET_IP="$DATA_IP"
            TARGET_PORT="$HTTPS_NODE_PORT"
            
            CONFIG_TOML="/host/etc/containerd/config.toml"
            HOSTS_DIR="/host/etc/containerd/certs.d/\$TARGET_IP:\$TARGET_PORT"
            HOSTS_FILE="\$HOSTS_DIR/hosts.toml"
            
            # === IDEMPOTENCY CHECK ===
            # If the hosts.toml exists, we assume configuration is done.
            if [ -f "\$HOSTS_FILE" ]; then
                echo "Certificate configuration for \$TARGET_IP already exists. Skipping."
                exit 0
            fi

            echo "Configuring Containerd for Harbor (\$TARGET_IP)..."

            # 1. Ensure containerd config exists and is valid
            if [ ! -f "\$CONFIG_TOML" ]; then
              mkdir -p /host/etc/containerd
              nsenter --mount=/proc/1/ns/mnt -- containerd config default > "\$CONFIG_TOML"
            fi
            
            # Enable certs.d config path if not enabled
            if grep -q 'config_path = ""' "\$CONFIG_TOML"; then
              sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|g' "\$CONFIG_TOML"
              NEED_RESTART=true
            fi

            # 2. Write Certificate and hosts.toml
            mkdir -p "\$HOSTS_DIR"
            cp /config/harbor.crt "\$HOSTS_DIR/ca.crt"
            
            echo "Generating hosts.toml..."
            printf 'server = "https://%s:%s"\n' "\$TARGET_IP" "\$TARGET_PORT" > "\$HOSTS_FILE"
            printf '[host."https://%s:%s"]\n' "\$TARGET_IP" "\$TARGET_PORT" >> "\$HOSTS_FILE"
            printf '  capabilities = ["pull", "resolve", "push"]\n' >> "\$HOSTS_FILE"
            printf '  ca = "/etc/containerd/certs.d/%s:%s/ca.crt"\n' "\$TARGET_IP" "\$TARGET_PORT" >> "\$HOSTS_FILE"

            # 3. Restart Containerd (only on first setup)
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

# Clean up and Apply DaemonSet
kubectl delete daemonset harbor-cert-installer -n $INSTALLER_NAMESPACE --ignore-not-found >/dev/null
kubectl apply -f "$CERT_CONFIGMAP_PATH"
kubectl apply -f "$CERT_DAEMONSET_PATH"

log "Waiting for certificate distribution..."
kubectl rollout status daemonset/harbor-cert-installer -n $INSTALLER_NAMESPACE --timeout=180s

step "5. Deploy Harbor Registry"
log "Upgrading/Installing Harbor..."
helm repo add harbor https://helm.goharbor.io 2>/dev/null
helm repo update > /dev/null

# We set externalURL to DATA_IP so Harbor provides the correct pull commands for high-speed transfer
helm upgrade --install harbor harbor/harbor \
  --namespace $HARBOR_NAMESPACE \
  --set harborAdminPassword="$HARBOR_ADMIN_PASSWORD" \
  --set expose.type=nodePort \
  --set expose.tls.enabled=true \
  --set expose.tls.certSource=secret \
  --set expose.tls.secret.secretName=harbor-https-secret \
  --set expose.tls.nodePort=$HTTPS_NODE_PORT \
  --set expose.nodePort.httpNodePort=$HTTP_NODE_PORT \
  --set externalURL="https://$DATA_IP:$HTTPS_NODE_PORT" \
  --set persistence.persistentVolumeClaim.registry.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.registry.size=200Gi \
  --set persistence.persistentVolumeClaim.jobservice.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.database.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.redis.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.trivy.storageClass=$STORAGE_CLASS \
  --set internalTLS.enabled=false \
  --wait

step "6. Deploy Prometheus & Grafana"
log "Configuring Kube-Prometheus-Stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null
helm repo update > /dev/null

cat <<EOF > /tmp/monitoring-values.yaml
grafana:
  service:
    type: NodePort
    nodePort: $GRAFANA_PORT
  persistence:
    enabled: true
    storageClass: $STORAGE_CLASS
    size: 10Gi
  grafana.ini:
    auth.anonymous:
      enabled: true
      org_role: Viewer
      org_name: GPU Cluster
    auth:
      disable_login_form: false
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
prometheus:
  prometheusSpec:
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

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace $MONITOR_NAMESPACE \
  --create-namespace \
  -f /tmp/monitoring-values.yaml \
  --wait

step "7. Deploy NVIDIA DCGM Exporter"
if [ ! -f "$DCGM_MANIFEST_PATH" ]; then
    warn "DCGM Manifest not found at $DCGM_MANIFEST_PATH! Skipping..."
else
    log "Deploying NVIDIA DCGM Exporter..."
    kubectl apply -f "$DCGM_MANIFEST_PATH"
fi

# Manual ServiceMonitor for DCGM
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
install_dashboard() {
    local ID=$1
    local NAME=$2
    local FILE="/tmp/${NAME}.json"
    log "Importing Dashboard: $NAME ($ID)..."
    curl -sL -o "$FILE" "https://grafana.com/api/dashboards/${ID}/revisions/latest/download"
    # Fix Datasource to Prometheus
    sed -i 's/"datasource": *"[^"]*"/"datasource": "Prometheus"/g' "$FILE"
    sed -i 's/${DS_PROMETHEUS}/Prometheus/g' "$FILE"
    kubectl create configmap "grafana-dashboard-${NAME}" \
      --namespace $MONITOR_NAMESPACE \
      --from-file="${NAME}.json=${FILE}" \
      --dry-run=client -o yaml | \
      kubectl label --local -f - grafana_dashboard=1 -o yaml | \
      kubectl apply -f -
    rm "$FILE"
}

install_dashboard 12239 "nvidia-gpu"
install_dashboard 15758 "ns-view"
install_dashboard 15761 "ns-compute"
install_dashboard 6417  "cluster-top"

log "Restarting Grafana to load dashboards..."
kubectl rollout restart deployment kube-prometheus-stack-grafana -n $MONITOR_NAMESPACE

step "9. Summary"
echo "========================================================"
echo -e "${GREEN}   DEPLOYMENT COMPLETE! ${NC}"
echo "========================================================"
echo -e "1. [UI/Management] Browser Access (1G Network):"
echo -e "   Harbor:  https://$UI_IP:$HTTPS_NODE_PORT"
echo -e "   Grafana: http://$UI_IP:$GRAFANA_PORT"
echo ""
echo -e "2. [Data/Storage] Docker/K8s Pulls (25G Network):"
echo -e "   Command: docker login $DATA_IP:$HTTPS_NODE_PORT"
echo -e "   Host:    $DATA_IP"
echo "========================================================"