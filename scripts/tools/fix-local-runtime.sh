#!/bin/bash
set -euo pipefail

# Fix containerd NVIDIA runtime and redeploy test pods.
# Steps:
# 1) Ensure nvidia runtime is configured for containerd (sets as default).
# 2) Allow NVIDIA_VISIBLE_DEVICES env in unprivileged containers.
# 3) Restart containerd.
# 4) Recreate test pods.

INFO() { echo "[INFO] $*"; }
ERR()  { echo "[ERROR] $*" >&2; }

CONFIG_NVIDIA_CTK() {
  INFO "Configuring containerd with nvidia-ctk (set as default runtime)..."
  sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
}

PATCH_NVIDIA_RUNTIME_CFG() {
  local cfg=/etc/nvidia-container-runtime/config.toml
  INFO "Patching ${cfg} to accept NVIDIA_VISIBLE_DEVICES for unprivileged containers..."
  if ! sudo test -f "$cfg"; then
    ERR "${cfg} not found"; return 1
  fi
  sudo python3 - <<'PY'
from pathlib import Path
p = Path('/etc/nvidia-container-runtime/config.toml')
text = p.read_text()
old = 'accept-nvidia-visible-devices-envvar-when-unprivileged = false'
new = 'accept-nvidia-visible-devices-envvar-when-unprivileged = true'
if old in text:
    text = text.replace(old, new)
elif new in text:
    pass
else:
    # Insert setting if missing
    text = text.replace('accept-nvidia-visible-devices-envvar-when-unprivileged', new)
p.write_text(text)
PY
}

RESTART_CONTAINERD() {
  INFO "Restarting containerd..."
  sudo systemctl restart containerd
}

REDEPLOY_TEST_PODS() {
  local manifest=/home/user/k8s/k8s-multicast-setting/manifests/test/mps-thread-test.yaml
  INFO "Redeploying test pods from ${manifest}..."
  kubectl delete pod mps-baseline mps-limited --force --grace-period=0 2>/dev/null || true
  kubectl apply -f "$manifest"
  INFO "Waiting for pods to finish..."
  kubectl wait --for=condition=Ready pod/mps-baseline pod/mps-limited --timeout=180s 2>/dev/null || true
  kubectl get pod mps-baseline mps-limited
}

main() {
  CONFIG_NVIDIA_CTK
  PATCH_NVIDIA_RUNTIME_CFG
  RESTART_CONTAINERD
  REDEPLOY_TEST_PODS
  INFO "Done. Check pod logs with: kubectl logs mps-baseline; kubectl logs mps-limited"
}

main "$@"
