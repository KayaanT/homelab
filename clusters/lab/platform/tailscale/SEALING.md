# Tailscale setup

## 1. ACL tags (must exist before the OAuth client)

In the admin console → **Access Controls**, add to the policy file:

```hujson
"tagOwners": {
  "tag:k8s-operator": [],
  "tag:k8s":          ["tag:k8s-operator"],
},
```

The operator owns `tag:k8s`, and devices it creates inherit it. Without this the
OAuth client cannot mint auth keys and the operator fails with a permissions
error that does not name the tag.

## 2. OAuth client

**Settings → OAuth clients → Generate**. Scopes: `Devices:Write` and
`Auth Keys:Write`, tagged `tag:k8s-operator`.

```bash
kubectl create secret generic operator-oauth \
  --namespace tailscale \
  --from-literal=client_id='<CLIENT_ID>' \
  --from-literal=client_secret='<CLIENT_SECRET>' \
  --dry-run=client -o yaml \
| kubeseal --format yaml > sealed-operator-oauth.yaml

git add sealed-operator-oauth.yaml && git commit -m "tailscale: oauth client"
```

## 3. Approve the advertised subnet route

The Connector advertises `LAN_CIDR` but Tailscale will not use it until you
approve it: **Machines → homelab-lan → Edit route settings**. Also tick **Use as
exit node** there. This is a manual step by design and a common place to get
stuck — the device appears healthy while nothing routes.

## 4. Enable Funnel

**Access Controls**, add:

```hujson
"nodeAttrs": [
  {"target": ["tag:k8s"], "attr": ["funnel"]},
],
```

Funnel only serves ports 443, 8443 and 10000; the operator handles that.

## 5. Split DNS so `*.__DOMAIN__` resolves over the tunnel

**DNS → Nameservers → Add nameserver → Custom**, set it to the k8s-gateway
LoadBalancer IP and restrict it to `__DOMAIN__`. Without this, internal
hostnames resolve on the LAN but not remotely — the single most common
"it works at home but not on cellular" cause.

## Verify

```bash
tailscale status                      # homelab-operator, homelab-lan listed
kubectl get svc -n tailscale          # API server proxy device
curl -I https://argocd-webhook.__TAILNET_NAME__/api/webhook   # from off-network
```
