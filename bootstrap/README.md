# Bootstrap

One-time, imperative. Everything after this is GitOps.

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m

# initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# hand the cluster over to Git
kubectl apply -f bootstrap/root-app.yaml
```

## Why Cilium is not managed by ArgoCD

ArgoCD runs *on* the cluster whose network Cilium provides. If Argo prunes or
mis-syncs the CNI, it severs the pod network — including its own — and cannot
recover itself. The Helm release is therefore installed and upgraded manually
via `host/phase1-cluster-init.sh`.

Cilium's *custom resources* (the LoadBalancer IP pool and L2 policy) are safe
to manage declaratively and are, in `clusters/lab/infra/cilium/`.

Same reasoning would apply to any component in the datapath.

## Sync waves

| Wave | Contents | Why here |
|------|----------|----------|
| 0 | sealed-secrets, cert-manager | Everything downstream needs secrets and certs |
| 1 | rook-ceph operator | Must exist before its CRs are valid |
| 2 | rook-ceph cluster | Creates the default StorageClass |
| 3 | observability, gateway, dns, twingate | Need storage for PVCs |
| 4 | workloads | Need all of the above |
