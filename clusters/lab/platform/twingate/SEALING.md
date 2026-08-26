# Twingate connector credentials

In the Twingate admin console: **Network → Connectors → Deploy Connector →
Docker**. It shows `TWINGATE_ACCESS_TOKEN` and `TWINGATE_REFRESH_TOKEN`.

```bash
kubectl create secret generic twingate-connector-keys \
  --namespace twingate \
  --from-literal=TWINGATE_ACCESS_TOKEN='<access>' \
  --from-literal=TWINGATE_REFRESH_TOKEN='<refresh>' \
  --dry-run=client -o yaml \
| kubeseal --format yaml > sealed-twingate-keys.yaml
```

## Resources to define in the Twingate console

| Resource | Address | Gets you |
|---|---|---|
| Cluster API | `k8s.<yourdomain>` | `kubectl` from anywhere |
| LAN services | `192.168.1.240/29` | every LoadBalancer IP |
| DNS | the k8s-gateway LB IP | name resolution off-LAN |

Set the Twingate client's DNS to the k8s-gateway IP, or internal hostnames
resolve on the LAN but not over the tunnel.
