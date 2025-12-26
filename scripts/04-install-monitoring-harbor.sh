#!/bin/bash
set -e

# --- Configurations ---
DATA_PATH="/data"
HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD:-"Harbor12345"}
GRAFANA_PORT=30003
HARBOR_PORT=30002

echo "=== Production Setup: Longhorn (/data) + NFS (Auto-Wired) + Monitoring + Harbor ==="

# 0. Pre-flight Check
if [ ! -d "$DATA_PATH" ]; then
  echo "[Error] Directory $DATA_PATH does not exist."
  echo "Please mount your 1.8TB drive to $DATA_PATH first."
  exit 1
fi
echo "[Check] Target storage path: $DATA_PATH"

# 1. Helm Check
if ! command -v helm &> /dev/null; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# 2. Storage: Longhorn
echo "[Storage] Installing Longhorn..."
sudo apt-get update -qq && sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

helm repo add longhorn https://charts.longhorn.io
helm repo update
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set defaultSettings.createDefaultDiskLabeledNodes=true \
  --set defaultSettings.defaultDataPath="$DATA_PATH" \
  --set persistence.defaultClassReplicaCount=1 \
  --set persistence.defaultClass=true

echo "Waiting for Longhorn Manager..."
kubectl wait --for=condition=ready pod -l app=longhorn-manager -n longhorn-system --timeout=300s

# Force Node Label (Crucial for the first node to use /data)
CURRENT_NODE=$(kubectl get node -o jsonpath='{.items[0].metadata.name}')
kubectl label node "$CURRENT_NODE" node.longhorn.io/create-default-disk=true --overwrite 2>/dev/null || true

# 3. Setup NFS Server (The Source)
echo "[Storage] Deploying NFS Server..."
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner
kubectl create namespace nfs-provisioner --dry-run=client -o yaml | kubectl apply -f -

# 3.1 Deploy Internal NFS Server
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-server-pvc
  namespace: nfs-provisioner
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 200Gi } }
  storageClassName: longhorn
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: nfs-server, namespace: nfs-provisioner }
spec:
  replicas: 1
  selector: { matchLabels: { app: nfs-server } }
  template:
    metadata: { labels: { app: nfs-server } }
    spec:
      containers:
      - name: nfs-server
        image: itsthenetwork/nfs-server-alpine:latest
        securityContext: { privileged: true }
        env:
        - name: SHARED_DIRECTORY
          value: "/exports"
        ports: [ { containerPort: 2049, name: nfs } ]
        volumeMounts: [ { name: export, mountPath: /exports } ]
      volumes:
      - name: export
        persistentVolumeClaim: { claimName: nfs-server-pvc }
---
apiVersion: v1
kind: Service
metadata: { name: nfs-server, namespace: nfs-provisioner }
spec:
  selector: { app: nfs-server }
  ports: [ { port: 2049, name: nfs } ]
EOF

echo "Waiting for NFS Server initialization..."
kubectl -n nfs-provisioner wait --for=condition=ready pod -l app=nfs-server --timeout=180s

# 3.2 Auto-Detect Service IP (General Method)
NFS_CLUSTER_IP=""
echo "Detecting NFS Service IP..."
while [ -z "$NFS_CLUSTER_IP" ]; do
  NFS_CLUSTER_IP=$(kubectl get svc -n nfs-provisioner nfs-server -o jsonpath='{.spec.clusterIP}')
  [ -z "$NFS_CLUSTER_IP" ] && sleep 2
done
echo "NFS Service IP detected: $NFS_CLUSTER_IP"

# 3.3 Deploy Provisioner using the Detected IP
echo "[Storage] Wiring NFS Provisioner to $NFS_CLUSTER_IP..."
helm upgrade --install nfs-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --namespace nfs-provisioner \
  --set nfs.server=$NFS_CLUSTER_IP \
  --set nfs.path=/exports \
  --set storageClass.name=longhorn-nfs \
  --set storageClass.create=true \
  --set storageClass.defaultClass=false

# 4. Monitoring
echo "[Monitoring] Installing Stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --reuse-values \
  --set grafana.service.nodePort=$GRAFANA_PORT \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.storageClass=longhorn \
  --set grafana.grafana\.ini.auth\.anonymous.enabled=true \
  --set grafana.grafana\.ini.auth\.anonymous.org_role=Viewer \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=longhorn

kubectl apply -f https://raw.githubusercontent.com/NVIDIA/dcgm-exporter/main/dcgm-exporter.yaml

# 5. Harbor (With TLS Fix)
echo "[Registry] Installing Harbor..."
helm repo add harbor https://helm.goharbor.io
helm repo update
kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -
EXT_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Note: Added expose.tls.auto.commonName=$EXT_IP to fix the "commonName required" error
helm upgrade --install harbor harbor/harbor \
  --namespace harbor \
  --set harborAdminPassword="$HARBOR_ADMIN_PASSWORD" \
  --set expose.type=nodePort \
  --set expose.tls.enabled=false \
  --set expose.tls.auto.commonName=$EXT_IP \
  --set externalURL="http://$EXT_IP:$HARBOR_PORT" \
  --set persistence.persistentVolumeClaim.registry.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.registry.size=100Gi \
  --set persistence.persistentVolumeClaim.jobservice.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.database.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.redis.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.trivy.storageClass=longhorn

echo "========================================================"
echo "   All Systems Operational"
echo "========================================================"
echo "1. Storage (Longhorn UI):"
echo "   kubectl port-forward -n longhorn-system svc/longhorn-frontend 8000:80"
echo "   -> http://localhost:8000"
echo "   Check: Node -> Path should be /data"
echo ""
echo "2. Monitoring (Grafana):"
echo "   URL:  http://$EXT_IP:$GRAFANA_PORT"
echo ""
echo "3. Registry (Harbor):"
echo "   URL:  http://$EXT_IP:$HARBOR_PORT"
echo "   User: admin / $HARBOR_ADMIN_PASSWORD"
echo "========================================================"

# kubectl get secret --namespace monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 --decode ; echo