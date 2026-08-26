#!/usr/bin/env bash
# Off-box backups. Ceph RGW and Velero both live on the same two partitions of
# the same physical disk as everything else - that is redundancy, not backup.
# This is the copy that survives the disk dying.
set -euo pipefail

: "${RESTIC_REPOSITORY:?set in /etc/restic-backup.env}"
: "${RESTIC_PASSWORD_FILE:?set in /etc/restic-backup.env}"
NODE="${HOMELAB_NODE:?set in /etc/restic-backup.env}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "etcd snapshot"
ssh "$NODE" 'sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /tmp/etcd.db && sudo chmod a+r /tmp/etcd.db'
scp -q "$NODE:/tmp/etcd.db" "$STAGE/etcd.db"
ssh "$NODE" 'sudo rm -f /tmp/etcd.db'

log "sealed-secrets key (without this, a rebuild cannot decrypt Git)"
ssh "$NODE" 'kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml' \
  > "$STAGE/sealed-secrets-key.yaml"

log "cluster state"
ssh "$NODE" 'kubectl get all,pvc,cm,ingress,httproute -A -o yaml' \
  > "$STAGE/cluster-state.yaml" 2>/dev/null || true

log "restic backup"
restic backup "$STAGE" --tag homelab --host "$NODE"

log "prune"
restic forget --tag homelab \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

log "verify"
restic check --read-data-subset=5%
