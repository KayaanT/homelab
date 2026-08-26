#!/usr/bin/env bash
# Phase 1 - install kubeadm, init the control plane, install Cilium.
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-v1.34}"   # VERIFY at https://kubernetes.io/releases/
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/homelab.env"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "Installing kubeadm/kubelet/kubectl (${K8S_MINOR})"
sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq kubelet kubeadm kubectl
# Never let an unattended upgrade move the control plane underneath you.
sudo apt-mark hold kubelet kubeadm kubectl

log "Ensuring k8s.${DOMAIN} resolves to ${NODE_IP}"
grep -q "k8s.${DOMAIN}" /etc/hosts || \
  echo "${NODE_IP} k8s.${DOMAIN}" | sudo tee -a /etc/hosts >/dev/null

log "kubeadm init (kube-proxy deliberately skipped)"
sudo kubeadm init --config "$REPO_ROOT/host/kubeadm.yaml" --skip-phases=addon/kube-proxy

mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

log "Untainting the control plane (single-node cluster)"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

log "Installing helm"
command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

log "Installing Gateway API CRDs (must precede Cilium with gatewayAPI=true)"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION:-v1.2.1}/standard-install.yaml"

log "Installing Cilium"
helm repo add cilium https://helm.cilium.io/ >/dev/null
helm repo update >/dev/null
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --values "$REPO_ROOT/clusters/lab/infra/cilium/values.yaml" \
  --wait --timeout 10m

log "Applying LoadBalancer IP pool + L2 announcement policy"
kubectl apply -f "$REPO_ROOT/clusters/lab/infra/cilium/lb-ipam.yaml"

cat <<'DONE'

Phase 1 verification:
  kubectl get nodes                      # Ready
  cilium status                          # all green (install the cilium CLI)
  kubectl get pods -A | grep kube-proxy  # MUST return nothing
  kubectl create deploy nginx --image=nginx
  kubectl expose deploy nginx --type=LoadBalancer --port=80
  kubectl get svc nginx                  # EXTERNAL-IP from your LAN pool
DONE
