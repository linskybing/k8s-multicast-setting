#!/bin/bash
set -e

echo "=== 1. Installing Helm ==="
if ! command -v helm &> /dev/null; then
    echo "Helm not found. Installing..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "Helm is already installed."
fi

echo "=== 2. Setting up Distributed Storage (Longhorn) ==="
# 2.1 Install Prerequisites (open-iscsi is required for Longhorn)
echo "Installing open-iscsi and nfs-common (required for Longhorn)..."
sudo apt-get update
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

# 2.2 Install Longhorn via Helm
echo "Adding Longhorn Helm Repository..."
helm repo add longhorn https://charts.longhorn.io
helm repo update

echo "Installing Longhorn..."
# We install in longhorn-system namespace
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set defaultSettings.createDefaultDiskLabeledNodes=true \
  --set persistence.defaultClassReplicaCount=1 \
  --set persistence.defaultClass=true

echo "Waiting for Longhorn to be ready (this may take a few minutes)..."
kubectl wait --for=condition=ready pod -l app=longhorn-manager -n longhorn-system --timeout=300s

echo "Longhorn installed. You can access the UI via Service/longhorn-frontend."

echo "=== 3. Adding Helm Repositories ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add harbor https://helm.goharbor.io
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

echo "=== 4. Installing Kube-Prometheus-Stack (Monitoring) ==="
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Install Prometheus + Grafana
# We enable serviceMonitorSelectorNilUsesHelmValues=false to allow discovering custom ServiceMonitors (like DCGM)
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.service.type=NodePort \
  --set prometheus.service.type=NodePort \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false

echo "=== 5. Installing DCGM Exporter (GPU Metrics) ==="
# This exports NVIDIA GPU metrics to Prometheus
# Note: The chart name in the official repo might vary or be deprecated.
# We use the standard helm chart from the GPU Operator or a direct manifest if helm fails.
# However, for standalone DCGM exporter, we can use the community chart or direct manifest.

echo "Attempting to install DCGM Exporter..."
# Using the official NVIDIA GPU Operator Helm repository which usually contains dcgm-exporter
# But sometimes it's better to use the direct manifest for simplicity in non-operator setups.

# Option 1: Try Helm (if available in repo)
if helm search repo nvidia/dcgm-exporter &> /dev/null; then
    helm upgrade --install dcgm-exporter nvidia/dcgm-exporter \
      --namespace monitoring \
      --set serviceMonitor.enabled=true
else
    echo "Helm chart not found. Falling back to K8s Manifest..."
    # Option 2: Use K8s Manifest (Stable and reliable for standalone)
    kubectl apply -f https://raw.githubusercontent.com/NVIDIA/dcgm-exporter/main/deployment/k8s/dcgm-exporter.yaml
    
    # Patch the service to have a label for ServiceMonitor (if needed later)
    # But for now, we just ensure it runs.
fi

echo "=== 6. Installing Harbor (Registry) ==="
kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -

# Install Harbor
# Note: We disable TLS for internal testing simplicity (expose.tls.enabled=false)
# We use NodePort to expose it.
helm upgrade --install harbor harbor/harbor \
  --namespace harbor \
  --set expose.type=nodePort \
  --set expose.tls.enabled=false \
  --set externalURL=http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'):30002 \
  --set persistence.persistentVolumeClaim.registry.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.jobservice.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.database.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.redis.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.trivy.storageClass=longhorn

echo "----------------------------------------------------------------"
echo "Installation initiated. It may take a few minutes for all pods to start."
echo ""
echo ">>> Longhorn UI Access <<<"
echo "Access via Port-Forward:"
echo "kubectl port-forward -n longhorn-system svc/longhorn-frontend 8000:80"
echo "(Then open http://localhost:8000)"
echo ""
echo ">>> Grafana Access <<<"
echo "Get Admin Password:"
echo "kubectl get secret --namespace monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 --decode ; echo"
echo "Access via Port-Forward:"
echo "kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
echo "(Then open http://localhost:3000)"
echo ""
echo ">>> Harbor Access <<<"
echo "Default User: admin"
echo "Default Pass: Harbor12345"
echo "Access via Port-Forward:"
echo "kubectl port-forward -n harbor svc/harbor-portal 8080:80"
echo "(Then open http://localhost:8080)"
echo "----------------------------------------------------------------"
