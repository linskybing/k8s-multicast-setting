#!/bin/bash

# Deploy the ROS2 application on the Kubernetes cluster

echo "Deploying ROS2 Talker and Listener..."

# We assume macvlan-conf was created by 02-install-cni-multicast.sh
# If not, we should warn the user.
if ! kubectl get network-attachment-definitions macvlan-conf > /dev/null 2>&1; then
    echo "Error: NetworkAttachmentDefinition 'macvlan-conf' not found."
    echo "Please run ./02-install-cni-multicast.sh first."
    exit 1
fi

# Deploy the ROS2 application (Talker and Listener)
kubectl apply -f ../manifests/ros2-app/deployment.yaml

# Create the service for the ROS2 application (Optional for multicast test, but good practice)
kubectl apply -f ../manifests/ros2-app/service.yaml

echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=ros2-talker --timeout=120s
kubectl wait --for=condition=ready pod -l app=ros2-listener --timeout=120s

echo "----------------------------------------------------------------"
echo "ROS2 application deployed successfully."
echo "To verify Multicast communication:"
echo "1. Check Talker logs: kubectl logs -l app=ros2-talker -f"
echo "2. Check Listener logs: kubectl logs -l app=ros2-listener -f"
echo "----------------------------------------------------------------"
echo "Checking logs now (Ctrl+C to exit)..."
echo "--- Listener Logs ---"
kubectl logs -l app=ros2-listener --tail=10
echo "--- Talker Logs ---"
kubectl logs -l app=ros2-talker --tail=10