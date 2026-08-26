# CoreDNS on the Pi

## Why not just the in-cluster one

The in-cluster CoreDNS serves *pods*. This one serves your *LAN*, and the whole
point is that it answers when the cluster is rebooting, upgrading, or broken.

## Simpler alternative

If `k8s_gateway` plus a kubeconfig feels like too much moving parts, replace the
first block with a static wildcard. One line, nothing to break, but you update
it by hand whenever the Gateway address changes:

```
__DOMAIN__ {
    template IN A {
        match .*
        answer "{{ .Name }} 60 IN A __LB_RANGE_START__"
    }
}
```

## Read-only kubeconfig for k8s_gateway

Give it a ServiceAccount that can only list the resources it needs — never copy
`admin.conf` onto another machine.

```bash
kubectl create namespace dns-reader
kubectl create serviceaccount k8s-gateway -n dns-reader

kubectl create clusterrole k8s-gateway-reader \
  --verb=list,watch \
  --resource=services,ingresses,httproutes.gateway.networking.k8s.io,gateways.gateway.networking.k8s.io

kubectl create clusterrolebinding k8s-gateway-reader \
  --clusterrole=k8s-gateway-reader \
  --serviceaccount=dns-reader:k8s-gateway

# 1-year token
kubectl create token k8s-gateway -n dns-reader --duration=8760h
```

Build a kubeconfig with that token and the cluster CA, and drop it at
`pi/coredns/kubeconfig`. It is gitignored.

**Set a calendar reminder for the token expiry.** A silently expired token
presents as DNS that stopped updating, which is a genuinely annoying thing to
diagnose a year later.
