# Decision log

Every choice here was forced by one number: **16GB of RAM on a single node.**
The reasoning matters more than the components.

## Cilium over Calico

Calico would have needed MetalLB for LoadBalancer IPs, ingress-nginx for HTTP
routing, and kube-proxy for services. Cilium does all four itself:

- eBPF datapath
- `kubeProxyReplacement: true` — no iptables service chains at all
- `l2announcements` — replaces MetalLB
- `gatewayAPI` — replaces ingress-nginx

Four components collapse into one. At 16GB that is roughly 400Mi of saved
overhead, and far fewer moving parts to debug. Hubble also gives flow-level
network visibility that Calico's free tier does not.

**Cost:** Cilium is harder to bootstrap. Without kube-proxy, the agent needs
`k8sServiceHost`/`k8sServicePort` to find the API server at all — omit them and
the CNI hangs with no useful error.

## kube-proxy skipped at init

`--skip-phases=addon/kube-proxy` is a one-time decision at `kubeadm init`.
Installing it and removing it later leaves stale iptables rules that silently
conflict with the eBPF datapath. Decide once, at the start.

## Ceph: replica 2, failureDomain osd, one mon

The default `failureDomain: host` cannot work on one host — CRUSH has nowhere to
put a second replica, so every placement group sits `undersized` forever.
Replicating across **OSDs** gives genuine redundancy against the failure that
actually exists here: a disk dying.

`size: 2` rather than 3 because there are only two OSDs, and `min_size: 1` so a
single OSD loss degrades rather than blocks I/O.

**One mon,** not three. Three mons on one node is theatre — they share a fate
domain, so there is no real quorum, and they cost ~1GB. The accepted cost: losing
the mon loses storage until it is restored from backup.

## OpenStack in a KVM guest, not dual-boot

Dual-boot gives OpenStack the full 16GB, but the Kubernetes cluster is then off
half the time — which makes it useless as a deploy target, and makes ArgoCD
pointless. It also hard-power-cycles Ceph on every switch, so time goes into
nursing a degraded cluster instead of learning.

Running OpenStack in a guest costs guest performance (nested virt, ~7.5GB) and
gains a cluster that is always up. Since the goal is understanding Nova
scheduling and Neutron networking rather than benchmarking guests, that is the
right trade.

## Twingate over a port-forwarded VPN

WireGuard would mean opening a UDP port on the home router and owning the key
rotation. The Twingate connector dials *outbound* to a relay, so the router keeps
every inbound port closed. Paired with DNS-01 certificates — which prove domain
ownership via a TXT record rather than an inbound HTTP challenge — the cluster is
fully reachable from anywhere with **zero** inbound exposure.

## Ollama over vLLM

vLLM is the correct production choice and is what a GPU deployment should use.
Its CPU build is slow and fragile. Ollama is reliable on CPU, handles quantized
GGUF models well, and the point of the AI layer here is the *platform* path —
Ceph volume, Gateway route, Twingate access — not tokens per second.

## ArgoCD does not manage Cilium

ArgoCD runs on the cluster whose pod network Cilium provides. A bad sync or a
prune would sever Argo's own networking, leaving nothing able to repair it.
Cilium's Helm release is managed manually; only its custom resources (LB pool,
L2 policy) are in Git.

## Sealed Secrets over SOPS

Both work. Sealed Secrets needs no ArgoCD plugin configuration, which is one
fewer thing to break during bootstrap. **Its weakness is the rebuild story:** the
sealing key lives in the cluster, so a wipe makes every committed secret
undecryptable unless the key was backed up first. SOPS+age has no such problem
and is the intended upgrade.

## Deliberately skipped

- **KServe / Knative** — the right way to serve models on Kubernetes, and far
  too heavy at this memory budget.
- **CephFS / MDS** — ~1GB for RWX volumes nothing currently needs.
- **Alertmanager** — nowhere to send alerts yet.
- **Multi-node HA anything** — one node. Pretending otherwise wastes RAM.
