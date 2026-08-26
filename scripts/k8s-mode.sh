#!/usr/bin/env bash
# Reverse of openstack-mode.sh.
set -euo pipefail
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "Shutting the OpenStack guest down gracefully"
sudo virsh shutdown openstack 2>/dev/null || true
for _ in $(seq 60); do
  sudo virsh domstate openstack 2>/dev/null | grep -q 'shut off' && break
  sleep 2
done

log "Restoring Ceph OSD memory target"
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph config set osd osd_memory_target 1610612736 || true

log "Scaling the platform back up"
kubectl -n argocd    scale --replicas=1 deploy/argocd-server deploy/argocd-repo-server \
                                        deploy/argocd-applicationset-controller 2>/dev/null || true
kubectl -n kube-system scale --replicas=1 deploy/hubble-relay deploy/hubble-ui   2>/dev/null || true

log "Re-enabling ArgoCD auto-sync (it restores everything else)"
kubectl -n argocd patch application observability --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true

echo "Done. Argo will reconcile the rest within a few minutes."
