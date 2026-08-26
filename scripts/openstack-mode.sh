#!/usr/bin/env bash
# Free ~4GB by parking the non-essential platform, then boot the OpenStack VM.
# The k8s API, Cilium, CoreDNS and Ceph stay up - the cluster never goes dark.
set -euo pipefail
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "Suspending ArgoCD auto-sync (or it will undo the scale-down in 3 minutes)"
for app in observability; do
  kubectl -n argocd patch application "$app" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null || true
done

log "Scaling down non-essential platform components"
kubectl -n observability scale --replicas=0 statefulset,deployment --all      2>/dev/null || true
kubectl -n kube-system   scale --replicas=0 deploy/hubble-relay deploy/hubble-ui 2>/dev/null || true
kubectl -n argocd        scale --replicas=0 deploy/argocd-server deploy/argocd-repo-server \
                                            deploy/argocd-applicationset-controller 2>/dev/null || true
kubectl -n rook-ceph     scale --replicas=0 deploy -l app=rook-ceph-rgw          2>/dev/null || true

log "Reducing Ceph OSD memory target to 1GiB"
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph config set osd osd_memory_target 1073741824 || true

log "Waiting for memory to be released"
for _ in $(seq 30); do
  avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  [[ $avail -gt 8500 ]] && break
  sleep 2
done
echo "  MemAvailable: $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo) MB"

log "Starting the OpenStack guest"
sudo virsh start openstack || sudo virsh list --all

echo
echo "Back to normal:  ./scripts/k8s-mode.sh"
