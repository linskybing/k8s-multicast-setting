#!/bin/bash
set -e

echo "=== Configuring Grafana for Public Access & Namespace Monitoring ==="

# 1. Enable Anonymous Access (Public View)
echo "Enabling Anonymous Access (Viewer Role)..."
# We use --reuse-values to preserve existing NodePort and other settings
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --reuse-values \
  --set grafana.grafana\.ini.auth\.anonymous.enabled=true \
  --set grafana.grafana\.ini.auth\.anonymous.org_role=Viewer

# 2. Add Namespace Dashboards
echo "Adding Kubernetes Namespace Dashboards..."

# Dashboard 1: Kubernetes / Views / Namespaces (ID: 15758)
# Provides a high-level overview of namespace health and resources
echo "Downloading Dashboard: Views / Namespaces..."
curl -L -o /tmp/ns-view.json https://grafana.com/api/dashboards/15758/revisions/latest/download

kubectl create configmap grafana-dashboard-ns-view \
  --namespace monitoring \
  --from-file=ns-view.json=/tmp/ns-view.json \
  --dry-run=client -o yaml > /tmp/ns-view-cm.yaml
kubectl label --local -f /tmp/ns-view-cm.yaml grafana_dashboard=1 -o yaml | kubectl apply -f -

# Dashboard 2: Kubernetes / Compute Resources / Namespace (Workloads) (ID: 15761)
# Provides detailed CPU/Memory usage breakdown by workload in a namespace
echo "Downloading Dashboard: Compute Resources / Namespace..."
curl -L -o /tmp/ns-compute.json https://grafana.com/api/dashboards/15761/revisions/latest/download

kubectl create configmap grafana-dashboard-ns-compute \
  --namespace monitoring \
  --from-file=ns-compute.json=/tmp/ns-compute.json \
  --dry-run=client -o yaml > /tmp/ns-compute-cm.yaml
kubectl label --local -f /tmp/ns-compute-cm.yaml grafana_dashboard=1 -o yaml | kubectl apply -f -

# Dashboard 3: Kubernetes Cluster (Prometheus) (ID: 6417)
# Provides a clear "Top Pods" view by CPU and Memory
echo "Downloading Dashboard: Cluster Top Pods (ID: 6417)..."
curl -L -o /tmp/cluster-top.json https://grafana.com/api/dashboards/6417/revisions/latest/download

kubectl create configmap grafana-dashboard-cluster-top \
  --namespace monitoring \
  --from-file=cluster-top.json=/tmp/cluster-top.json \
  --dry-run=client -o yaml > /tmp/cluster-top-cm.yaml
kubectl label --local -f /tmp/cluster-top-cm.yaml grafana_dashboard=1 -o yaml | kubectl apply -f -

# Cleanup
rm /tmp/ns-view.json /tmp/ns-view-cm.yaml /tmp/ns-compute.json /tmp/ns-compute-cm.yaml /tmp/cluster-top.json /tmp/cluster-top-cm.yaml

# 3. Get Node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "----------------------------------------------------------------"
echo "Configuration Complete!"
echo "Grafana is now publicly accessible (No Login Required)."
echo ""
echo "Namespace Overview Dashboard:"
echo "http://$NODE_IP:30003/d/k8s-views-namespaces?orgId=1&refresh=10s"
echo ""
echo "📈 Detailed Compute Resources (CPU/Memory) by Namespace:"
echo "http://$NODE_IP:30003/d/k8s-resources-namespace?orgId=1&refresh=10s"
echo ""
echo "🏆 Cluster Top Pods (Resource Hogs):"
echo "http://$NODE_IP:30003/d/1/kubernetes-cluster-prometheus?orgId=1&refresh=10s&var-datasource=default&var-cluster=default"
echo ""
echo "👉 Use the 'Namespace' dropdown at the top of the dashboard to select your namespace."
echo "----------------------------------------------------------------"
