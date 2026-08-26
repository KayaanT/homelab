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

## Tailscale over Twingate (and over a port-forwarded VPN)

All three give remote access. The differences are structural.

A **port-forwarded WireGuard** endpoint means opening a UDP port on the home
router and owning key rotation by hand. Ruled out immediately.

**Twingate** is a ZTNA proxy: you define Resources and grant per-resource
access, traffic is brokered client -> relay -> connector, and a client never
holds an IP on the LAN, so lateral movement is structurally impossible. That is
genuinely stronger isolation, and it is the right model for an organisation with
many users and an audit requirement.

**Tailscale** is a mesh VPN: devices join a tailnet and talk peer-to-peer over
WireGuard, with relays only as a NAT-traversal fallback.

Tailscale wins here because Twingate's advantages are all multi-user features
that never activate with a single operator, while Tailscale's advantages apply
immediately and every day:

- **Subnet router** — the whole LAN becomes reachable, including devices that
  cannot run a client: the router admin page, a printer, IPMI, and the
  OpenStack Horizon UI inside the KVM guest.
- **Exit node** — route a laptop's full traffic through home on untrusted wifi.
- **Funnel** — expose exactly one path to the public internet with a
  Tailscale-provisioned TLS cert and still no inbound port. This turns ArgoCD's
  3-minute Git polling into an instant push-triggered sync, and it is the
  general answer for any future project needing a public callback.
- **Peer-to-peer** — direct WireGuard rather than a relay hop, so latency and
  throughput are materially better.
- **Self-hostable** — Headscale, below. Twingate has no equivalent.

**Accepted cost:** a compromised device gets network-level reach across the
tailnet rather than access to one named resource. Mitigated with ACL tags and
short key expiry, but it is a real downgrade in blast radius, and the honest
reason to accept it is that there is one user and one device class here.

## Headscale — optional, later

Headscale is an open-source reimplementation of Tailscale's coordination
server. Running it on this cluster means the control plane is self-hosted -
no dependency on Tailscale's SaaS for the network to function.

Deferred rather than done first, deliberately: it is the piece most likely to
break remote access, and losing remote access to a headless box is the one
failure that requires physically walking over to it. Get the cluster stable and
reachable on hosted Tailscale, then migrate.

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
