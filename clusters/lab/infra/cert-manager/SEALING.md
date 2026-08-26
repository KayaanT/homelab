# Sealing the Cloudflare token

The token needs exactly `Zone:DNS:Edit` scoped to your zone. Nothing more.

```bash
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token='<TOKEN>' \
  --dry-run=client -o yaml \
| kubeseal --format yaml > sealed-cloudflare-token.yaml

git add sealed-cloudflare-token.yaml && git commit -m "cert-manager: cloudflare token"
```

The sealed file is safe in a public repo — it can only be decrypted by the
controller key on this specific cluster. **That also means: back up the sealing
key, or a rebuild cannot decrypt anything you committed.**

```bash
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key-BACKUP.yaml   # store OFF the cluster, encrypted
```
