#!/bin/bash
echo "=== Kubernetes Join Command ==="
echo "Run the following command on your worker node to join the cluster:"
echo ""
kubeadm token create --print-join-command
echo ""
echo "==============================="
