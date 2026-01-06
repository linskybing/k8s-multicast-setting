#!/bin/bash
set -e

# --- Configuration ---
HARBOR_NAMESPACE="harbor"
HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD:-"HarborProd123!"}
# HTTPS Port (NodePort)
HTTPS_NODE_PORT=30003
# HTTP Port (Redirect to HTTPS)
HTTP_NODE_PORT=30002
# CA/Manifest paths
CERTS_DIR="certs"
CERT_CONFIGMAP_PATH="/tmp/harbor-ca-configmap.yaml"
CERT_DAEMONSET_PATH="/tmp/harbor-ca-daemonset.yaml"

# Color Definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }

echo "========================================================"
echo "   Harbor Deployment with Self-Signed HTTPS             "
echo "========================================================"

# 1. Get External IP
EXT_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
log "Detected External IP: $EXT_IP"

# 2. Generate Self-Signed Certificates
log "Generating Self-Signed Certificates..."
mkdir -p "$CERTS_DIR"

# Generate CA
openssl genrsa -out "$CERTS_DIR/ca.key" 4096
openssl req -x509 -new -nodes -sha512 -days 3650 \
 -subj "/C=TW/ST=Taiwan/L=Taipei/O=MyOrg/OU=IT/CN=$EXT_IP" \
 -key "$CERTS_DIR/ca.key" \
 -out "$CERTS_DIR/ca.crt"

# Generate Server Key
openssl genrsa -out "$CERTS_DIR/harbor.key" 4096

# Generate CSR
openssl req -new -key "$CERTS_DIR/harbor.key" -out "$CERTS_DIR/harbor.csr" \
  -subj "/C=TW/ST=Taiwan/L=Taipei/O=MyOrg/OU=IT/CN=$EXT_IP"

# Generate Extension file for SAN (Subject Alternative Name) - CRITICAL for IP access
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

log "Certificates generated in ./$CERTS_DIR"

# 3. Create Namespace & Secret
log "Configuring Kubernetes Secret..."
kubectl create namespace $HARBOR_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Delete old secret if exists
kubectl -n $HARBOR_NAMESPACE delete secret harbor-https-secret --ignore-not-found

# Create new TLS secret
kubectl -n $HARBOR_NAMESPACE create secret tls harbor-https-secret \
  --key "$CERTS_DIR/harbor.key" \
  --cert "$CERTS_DIR/harbor.crt"

# 4. Distribute CA to every node (containerd trust + hosts.toml)
log "Distributing Harbor CA to all nodes (containerd trust store)..."

# Recreate ConfigMap with the freshly generated CA
cat > "$CERT_CONFIGMAP_PATH" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: harbor-ca-cert
  namespace: default
data:
  harbor.crt: |
$(sed 's/^/    /' "$CERTS_DIR/ca.crt")
EOF

cat > "$CERT_DAEMONSET_PATH" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: harbor-cert-installer
  namespace: default
  labels:
    app: harbor-cert-installer
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

            CONFIG_TOML="/host/etc/containerd/config.toml"
            TARGET_DIR="/host/etc/containerd/certs.d/$EXT_IP:$HTTPS_NODE_PORT"

            if [ ! -f "\$CONFIG_TOML" ]; then
              echo "Generating default containerd config..."
              mkdir -p /host/etc/containerd
              nsenter --mount=/proc/1/ns/mnt -- sh -c "containerd config default > \\\${CONFIG_TOML}"
            fi

            if grep -q 'config_path = ""' "\$CONFIG_TOML"; then
              sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|g' "\$CONFIG_TOML"
              echo "Set config_path in config.toml"
            elif ! grep -q 'config_path = "/etc/containerd/certs.d"' "\$CONFIG_TOML"; then
              echo "[WARN] config_path not found or different in \$CONFIG_TOML; please verify." >&2
            fi

            mkdir -p "\$TARGET_DIR"
            cp /config/harbor.crt "\$TARGET_DIR/ca.crt"

            cat > "\$TARGET_DIR/hosts.toml" <<INNEREOF
            server = "https://$EXT_IP:$HTTPS_NODE_PORT"
            [host."https://$EXT_IP:$HTTPS_NODE_PORT"]
              capabilities = ["pull", "resolve", "push"]
              ca = "/etc/containerd/certs.d/$EXT_IP:$HTTPS_NODE_PORT/ca.crt"
            INNEREOF

            if [ -d "/host/usr/local/share/ca-certificates" ]; then
              cp /config/harbor.crt /host/usr/local/share/ca-certificates/harbor.crt
              nsenter --mount=/proc/1/ns/mnt -- sh -c "update-ca-certificates"
            fi

            nsenter --mount=/proc/1/ns/mnt -- systemctl restart containerd
            echo "Harbor CA installed and containerd restarted."
        volumeMounts:
        - name: host-etc-containerd
          mountPath: /host/etc/containerd
        - name: host-usr-local-share
          mountPath: /host/usr/local/share
        - name: cert-config
          mountPath: /config
      containers:
      - name: pause
        image: k8s.gcr.io/pause:3.6
      volumes:
      - name: host-etc-containerd
        hostPath:
          path: /etc/containerd
      - name: host-usr-local-share
        hostPath:
          path: /usr/local/share
      - name: cert-config
        configMap:
          name: harbor-ca-cert
EOF

kubectl delete daemonset harbor-cert-installer --ignore-not-found -n default
kubectl delete configmap harbor-ca-cert --ignore-not-found -n default
kubectl apply -f "$CERT_CONFIGMAP_PATH"
kubectl apply -f "$CERT_DAEMONSET_PATH"
kubectl rollout status daemonset/harbor-cert-installer -n default --timeout=180s || warn "DaemonSet rollout not confirmed; verify containerd on all nodes."

# 5. Deploy Harbor with HTTPS
log "Deploying Harbor via Helm..."
helm repo add harbor https://helm.goharbor.io 2>/dev/null
helm repo update > /dev/null

if helm list -n $HARBOR_NAMESPACE | grep -q "harbor"; then
    log "Harbor is already installed. Skipping installation..."
else
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
      --set persistence.persistentVolumeClaim.registry.storageClass=nfs-client \
      --set persistence.persistentVolumeClaim.registry.size=200Gi \
      --set persistence.persistentVolumeClaim.jobservice.storageClass=nfs-client \
      --set persistence.persistentVolumeClaim.database.storageClass=nfs-client \
      --set persistence.persistentVolumeClaim.redis.storageClass=nfs-client \
      --set persistence.persistentVolumeClaim.trivy.storageClass=nfs-client \
      --wait
fi

# --- 8. Deploy Monitoring ---
log "Step 6: Deploying Monitoring Stack..."

# Check if Monitoring is already installed
if helm list -n monitoring | grep -q "kube-prometheus-stack"; then
    log "Monitoring stack already installed. Skipping..."
else
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    # Using local variables if defined, otherwise defaults
    GRAFANA_PORT=${GRAFANA_PORT:-30004}
    STORAGE_CLASS="nfs-client"

    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --set grafana.service.type=NodePort \
      --set grafana.service.nodePort=$GRAFANA_PORT \
      --set grafana.persistence.enabled=true \
      --set grafana.persistence.storageClass=$STORAGE_CLASS \
      --set grafana.persistence.size=10Gi \
      --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=$STORAGE_CLASS \
      --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi
fi

# 5. Summary & Client Config
echo "========================================================"
log "Harbor Deployed Successfully with HTTPS!"
echo "========================================================"
echo -e "   URL:      https://$EXT_IP:$HTTPS_NODE_PORT"
echo -e "   User:     admin"
echo -e "   Password: $HARBOR_ADMIN_PASSWORD"
echo "--------------------------------------------------------"
warn "IMPORTANT: Since this is a Self-Signed Certificate, you MUST configure your Docker clients:"
echo ""
echo "Step 1: On every machine that needs to pull/push images (including K8s nodes):"
echo "   sudo mkdir -p /etc/docker/certs.d/$EXT_IP:$HTTPS_NODE_PORT"
echo "   sudo cp $(pwd)/certs/ca.crt /etc/docker/certs.d/$EXT_IP:$HTTPS_NODE_PORT/ca.crt"
echo ""
echo "Step 2: Restart Docker"
echo "   sudo systemctl restart docker"
echo "========================================================"