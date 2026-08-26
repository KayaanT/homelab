# Version pins — VERIFY ALL OF THESE BEFORE THE FIRST SYNC

Every version below was written from memory and may be stale or wrong. Check
each one and correct it in the referenced file. This takes ten minutes and saves
an afternoon of confusing sync failures.

| Component | File | Pinned | Check at |
|---|---|---|---|
| Kubernetes minor | `host/phase1-cluster-init.sh` (`K8S_MINOR`) | v1.34 | https://kubernetes.io/releases/ |
| Gateway API CRDs | `host/phase1-cluster-init.sh` (`GATEWAY_API_VERSION`) | v1.2.1 | Cilium docs — must match what your Cilium version supports |
| Cilium chart | installed by helm, unpinned | latest | `helm search repo cilium/cilium` |
| sealed-secrets | `infra/sealed-secrets/app.yaml` | 2.17.3 | `helm search repo` |
| cert-manager | `infra/cert-manager/app.yaml` | v1.16.2 | https://cert-manager.io |
| rook-ceph | `infra/rook-ceph-operator/app.yaml` | v1.16.2 | https://rook.io |
| ceph image | `infra/rook-ceph-cluster/manifests/cluster.yaml`, `toolbox.yaml` | v19.2.1 | must be a version your Rook release supports |
| k8s-gateway | `platform/dns/app.yaml` | 2.4.0 | https://github.com/ori-edge/k8s_gateway |
| twingate connector | `platform/twingate/app.yaml` | 0.1.29 | https://github.com/Twingate/helm-charts |
| kube-prometheus-stack | `platform/observability/app.yaml` | 67.5.0 | `helm search repo` |

Fastest way to check the Helm ones on the box:

```bash
for r in "sealed-secrets https://bitnami-labs.github.io/sealed-secrets" \
         "jetstack https://charts.jetstack.io" \
         "rook-release https://charts.rook.io/release" \
         "k8s-gateway https://ori-edge.github.io/k8s_gateway/" \
         "twingate https://twingate.github.io/helm-charts" \
         "prometheus-community https://prometheus-community.github.io/helm-charts"; do
  helm repo add $r >/dev/null 2>&1
done
helm repo update >/dev/null
helm search repo --versions | head -50
```

**The Ceph image and the Rook version are coupled.** Rook only supports a
window of Ceph releases; mismatching them produces an operator that refuses to
create the cluster with a message that does not obviously say why.
