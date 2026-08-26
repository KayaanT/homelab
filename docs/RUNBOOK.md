# Build Runbook

> **Reading this cold?** This repo contains the working files; the sections
> below explain *why* each one is shaped the way it is. Start with the README
> for the architecture and the RAM budget, then `docs/decisions.md`, then here.
>
> **Before the first ArgoCD sync, read `docs/versions.md` and verify every
> pinned chart version.** They were written from memory and may be stale.

## Phase → file map

| Phase | What | Files |
|---|---|---|
| -1 | Wipe Windows, install Ubuntu, BIOS | `docs/FROM-WINDOWS.md`, `docs/WIFI.md` |
| 0 | Host prep, disk wipe | `host/phase0-prep.sh`, `host/wipe-ceph-disks.sh` |
| 1 | kubeadm + Cilium | `host/kubeadm.yaml`, `host/phase1-cluster-init.sh`, `clusters/lab/infra/cilium/` |
| 2 | ArgoCD / GitOps | `bootstrap/` |
| 3 | Rook-Ceph | `clusters/lab/infra/rook-ceph-{operator,cluster}/` |
| 4 | DNS, TLS, Tailscale | `clusters/lab/infra/cert-manager/`, `clusters/lab/platform/{gateway,dns,tailscale}/` |
| 5 | Observability | `clusters/lab/platform/observability/` |
| 6 | AI workloads | `clusters/lab/workloads/` |
| 7 | OpenStack | `scripts/openstack-mode.sh`, `scripts/k8s-mode.sh` (guest built by hand, §7) |
| 8 | Packaging | `README.md`, `docs/decisions.md` |

Config lives in one place: edit `homelab.env`, then run `./scripts/configure.sh`
to substitute the `__PLACEHOLDER__` tokens across every manifest.

---


## Context

A spare box (i7 11th-gen, 16GB RAM, ~500GB SSD) becomes an always-on private
cloud serving three purposes: learning AI infrastructure, a public resume
artifact, and a real deploy target for future projects.

The binding constraint is 16GB of RAM. A tuned Kubernetes + Rook-Ceph +
observability stack lands ~10.5GB. An OpenStack control plane wants 8GB alone.
So: **Kubernetes runs on bare metal permanently; OpenStack runs in a KVM guest
started on demand** after a script scales down the heavy k8s components. No dual
boot — the cluster must stay up to be useful as a deploy target.

Decided: **kubeadm**, **Cilium** (Calico dropped), **Rook-Ceph on two raw
partitions of the internal SSD**, **ArgoCD** as the deployment mechanism,
**Tailscale** for remote access, **CPU-only** AI workloads, **Kolla-Ansible** for
OpenStack.

---

## Prerequisites to acquire before Phase 0

| Item | Cost | Needed for | If you skip it |
|---|---|---|---|
| A domain on Cloudflare | ~$10/yr | Real TLS certs via DNS-01 | Fallback below |
| Cloudflare API token (Zone:DNS:Edit, scoped to that zone) | free | cert-manager | — |
| GitHub account | free | The GitOps repo | Blocking — no fallback |
| Tailscale account (free tier) | free | Remote access | Blocking for Phase 4 |
| Ubuntu Server 24.04 LTS ISO on a USB stick | free | Phase 0 | Blocking |
| USB3 gigabit ethernet adapter | ~$15 | LAN LoadBalancer IPs; a more realistic Phase 7 topology | **Optional.** The entire build works on WiFi — see `docs/WIFI.md` |

**No-domain fallback:** cert-manager can run a self-signed `ClusterIssuer` and
you install its CA cert on your devices. Everything works; browsers are happy
only on machines you've trusted. A domain is worth the $10 — DNS-01 with a real
cert and no open ports is one of the better things to be able to explain.

---

## Execution model

Do Phase 0 by hand at the keyboard. After that, SSH in from your Mac and install
Claude Code **on the box** so it can run commands against the real cluster:

```bash
# on the homelab box, after Phase 0
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs git
npm install -g @anthropic-ai/claude-code
claude
```

Then work phase by phase, handing it this file. Phases 1–8 are all
command-driven and safe to iterate on.

---

## Resource budget

This table is the plan. Everything else is downstream of it, and it's also the
most interesting content for the writeup.

### Normal mode (Kubernetes)

| Component | Budget | Notes |
|---|---|---|
| Ubuntu + containerd + kubelet | 1.2 GB | |
| Control plane (apiserver/etcd/cm/sched) | 1.1 GB | apiserver dominates |
| Cilium agent + operator | 0.5 GB | |
| Hubble relay + UI | 0.3 GB | scale to 0 when not demoing |
| CoreDNS | 0.1 GB | |
| Rook: mon(1) + mgr(1) | 1.0 GB | |
| Rook: 2 × OSD | 3.0 GB | `osd_memory_target` pinned to 1.5GiB |
| Rook: RGW (S3) | 0.5 GB | |
| ArgoCD | 0.6 GB | dex disabled |
| cert-manager + sealed-secrets | 0.2 GB | |
| Tailscale operator + connector | 0.2 GB | subnet router + exit node |
| kube-prometheus-stack | 1.8 GB | 7d retention, 30s scrape |
| **Platform subtotal** | **~10.4 GB** | |
| **Free for workloads** | **~5.5 GB** | fits Ollama + a 3B Q4 model |

### OpenStack mode

Scale down Prometheus, Hubble, ArgoCD, RGW; drop `osd_memory_target` to 1GiB.
Frees ~4GB, leaving ~7.5GB for the guest. Kolla's documented AIO minimum is 8GB,
so this runs slightly under spec — compensate by disabling Cinder, Heat, Octavia,
Barbican, Swift, and telemetry.

### Disk layout — partition manually during the Ubuntu install

```
nvme0n1p1   1 GiB    EFI
nvme0n1p2   2 GiB    /boot
nvme0n1p3 200 GiB    LVM PV → vg0
                       lv_root     110 GiB  (/, incl. /var/lib/containerd)
                       lv_libvirt   80 GiB  (/var/lib/libvirt/images)
                       ~10 GiB free for LVM snapshots
nvme0n1p4 120 GiB    RAW — Ceph OSD 0   (no filesystem, no LVM)
nvme0n1p5 120 GiB    RAW — Ceph OSD 1   (no filesystem, no LVM)
~20 GiB unallocated tail (spare / third OSD later)
```

**No swap.** Kubelet requires it off.

---

## Phase 0 — Host preparation (do this at the keyboard)

Install Ubuntu Server 24.04 LTS, manual partitioning per above. Create p4/p5 as
unformatted partitions — do not assign mount points.

Wire the USB ethernet adapter in and set a **DHCP reservation** on the router
for its MAC (preferred over a static netplan address — it survives router
changes and cannot collide). Note the address; it is referenced throughout as
`$NODE_IP`. Keep WiFi configured as a lower-priority fallback so a dead USB NIC
does not strand a headless box — see `docs/WIFI.md`.

```bash
# --- laptop chassis only: stay awake with the lid shut ---
sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/;
             s/^#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/;
             s/^#\?HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
sudo systemctl restart systemd-logind

# --- all machines ---
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

sudo swapoff -a
sudo sed -i '/\sswap\s/ s/^/#/' /etc/fstab

cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay br_netfilter

cat <<'EOF' | sudo tee /etc/sysctl.d/99-k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

sudo apt-get update && sudo apt-get install -y containerd chrony
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
```

**Wipe the Ceph partitions.** Rook silently skips any device carrying a
filesystem or LVM signature — this is the most common Rook-on-bare-metal failure,
and it presents as "OSDs never appear" with no error.

```bash
for p in /dev/nvme0n1p4 /dev/nvme0n1p5; do
  sudo wipefs -a "$p"
  sudo dd if=/dev/zero of="$p" bs=1M count=100 oflag=direct,dsync
  sudo blkdiscard -f "$p" || true
done
lsblk -f    # p4 and p5 must show empty FSTYPE
```

SSH: key auth only, `PasswordAuthentication no`. Enable `unattended-upgrades`.

**Phase 0 done when:** `free -h` shows no swap, `lsblk -f` shows p4/p5 with blank
FSTYPE, and the box stays reachable over SSH with the lid closed / display off.

---

## Phase 1 — Kubernetes (kubeadm) + Cilium

### 1a. Install kubeadm

Check https://kubernetes.io/releases/ for the current stable minor and set it:

```bash
K8S_MINOR=v1.34   # verify before running
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

The `apt-mark hold` matters — you do not want an unattended upgrade moving the
control plane under you.

### 1b. Init the cluster

Add `k8s.lab.<yourdomain>` → `$NODE_IP` to your DNS (or `/etc/hosts` for now).
Using a DNS name rather than a bare IP puts the right SAN in the API server cert,
so you aren't regenerating certs when you reach it through Tailscale later.

`kubeadm.yaml` (commit this to the repo):

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: stable
controlPlaneEndpoint: "k8s.lab.<yourdomain>:6443"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

```bash
sudo kubeadm init --config kubeadm.yaml --skip-phases=addon/kube-proxy

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# single node: allow workloads on the control plane
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

`--skip-phases=addon/kube-proxy` must be decided here — Cilium replaces it with
eBPF. There will be no kube-proxy pods, and that's correct.

### 1c. Cilium

Gateway API CRDs **first** (check the Cilium docs for the version it expects):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

`infra/cilium/values.yaml`:

```yaml
kubeProxyReplacement: true
k8sServiceHost: "k8s.lab.<yourdomain>"   # or $NODE_IP
k8sServicePort: 6443
ipam:
  mode: kubernetes
bpf:
  masquerade: true
l2announcements:
  enabled: true
externalIPs:
  enabled: true
gatewayAPI:
  enabled: true
hubble:
  relay:
    enabled: true
  ui:
    enabled: true
# l2announcements is chatty against the API server
k8sClientRateLimit:
  qps: 20
  burst: 100
```

```bash
helm repo add cilium https://helm.cilium.io/ && helm repo update
helm install cilium cilium/cilium -n kube-system -f infra/cilium/values.yaml
```

`k8sServiceHost`/`k8sServicePort` are **required** without kube-proxy — omit them
and the agent can't reach the API server to bootstrap. It presents as a hanging
CNI with no obvious error.

LoadBalancer IPs — pick a range **outside your router's DHCP scope**:

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata: {name: lan-pool}
spec:
  blocks:
    - start: "192.168.1.240"
      stop:  "192.168.1.250"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata: {name: lan-l2}
spec:
  interfaces: ["^enp.*", "^eth.*"]
  externalIPs: true
  loadBalancerIPs: true
```

**Phase 1 done when:** `kubectl get nodes` is Ready, `cilium status` is green,
`kubectl get pods -A | grep kube-proxy` returns nothing, and a test
`LoadBalancer` Service gets a LAN IP that answers from your Mac.

---

## Phase 2 — GitOps with ArgoCD

### 2a. Create the repo

```bash
gh auth login
mkdir ~/homelab && cd ~/homelab && git init -b main

mkdir -p bootstrap clusters/lab/{infra,platform,workloads} docs scripts
# move kubeadm.yaml + infra/cilium/values.yaml in here

gh repo create homelab --public --source=. --remote=origin
git add -A && git commit -m "bootstrap: host config, kubeadm, cilium" && git push -u origin main
```

Public from day one. This repo *is* the resume artifact.

### 2b. Install ArgoCD, then hand it to itself

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Install it imperatively **once**. Then commit its manifests and let Argo manage
its own deployment. From here on, nothing reaches the cluster except through Git.

### 2c. App-of-apps with sync waves

`bootstrap/root-app.yaml` points at `clusters/lab/`, and each child Application
carries `argocd.argoproj.io/sync-wave`:

| Wave | Contents |
|---|---|
| 0 | CRDs, cert-manager, sealed-secrets |
| 1 | Rook operator |
| 2 | CephCluster, StorageClasses |
| 3 | observability, Gateway, DNS, Tailscale |
| 4 | workloads |

Ordering becomes declarative rather than a README instruction.

**Secrets: Sealed Secrets.** Fully GitOps, no ArgoCD plugin config, works
offline. Encrypt with `kubeseal`, commit the sealed output. SOPS+age is the
upgrade path once things are stable — record that in `docs/decisions.md` rather
than starting there.

**Phase 2 done when:** ArgoCD shows its own Application as Synced/Healthy, and
`kubectl delete` on a managed resource results in Argo recreating it.

---

## Phase 3 — Rook-Ceph

Operator via Helm (wave 1), `CephCluster` CR (wave 2):

```yaml
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata: {name: rook-ceph, namespace: rook-ceph}
spec:
  cephVersion: {image: quay.io/ceph/ceph:v19}   # check current stable
  dataDirHostPath: /var/lib/rook
  mon:   {count: 1, allowMultiplePerNode: false}
  mgr:   {count: 1}
  dashboard: {enabled: true, ssl: false}
  storage:
    useAllNodes: false
    useAllDevices: false
    nodes:
      - name: "<node-name>"          # must match `kubectl get nodes`
        devices:
          - name: "nvme0n1p4"
          - name: "nvme0n1p5"
  cephConfig:
    global:
      osd_memory_target: "1610612736"   # 1.5 GiB
```

Then a `CephBlockPool` with `failureDomain: osd`, `replicated.size: 2`,
`min_size: 1` → default StorageClass. Replication across OSDs rather than hosts
is the correct single-node pattern, and knowing *why* is worth writing down.

`mon.count: 1` is deliberate: three mons on one node teaches nothing about quorum
and costs ~1GB. The tradeoff is that a mon failure downs storage — so back up the
mon store.

Also deploy:
- **`CephObjectStore` (RGW)** → an S3 endpoint. This is the AI-infra tie-in; it
  becomes the MLflow artifact store and Velero target in Phase 6.
- **Toolbox pod** for `ceph -s` / `ceph osd tree`.
- **Skip `CephFilesystem`/MDS** initially (saves ~1GB). Add only when something
  genuinely needs RWX.

**Phase 3 done when:** `ceph -s` reports `HEALTH_OK` with 2 OSDs up/in, a PVC
binds and a pod writes to it, and `aws s3 --endpoint-url ...` can put and get an
object.

---

## Phase 4 — DNS, TLS, remote access

Goal: **zero inbound ports on the router.**

**cert-manager with a Cloudflare DNS-01 solver.** DNS-01 proves domain ownership
via a TXT record, so you get genuine Let's Encrypt certs for internal-only names
with nothing exposed to the internet. Cloudflare API token goes in as a Sealed
Secret.

**CoreDNS — the honest version:** the in-cluster CoreDNS already ships with
kubeadm; there is nothing to install. The interesting half is LAN-side
resolution. Deploy **k8s_gateway** as a LoadBalancer Service answering
`*.lab.<yourdomain>` with Cilium LB IPs, and point the router's DNS at it. That's
split-horizon DNS: the same name resolves publicly to nothing and internally to
your cluster.

**Tailscale:** deploy the Kubernetes operator via Helm, OAuth credentials as a
Sealed Secret. It connects outbound, so the router keeps every inbound port
closed. Three pieces beyond plain remote access:

- a **Connector** advertising the LAN CIDR (subnet router) and acting as an
  **exit node**
- the **API server proxy**, putting the cluster API on the tailnet as its own
  device so `kubectl` needs no LAN IPs
- a **Funnel** Ingress on ArgoCD's `/api/webhook`, so GitHub pushes trigger an
  immediate sync instead of waiting for the 3-minute poll

Two manual console steps that are easy to miss: **approve the advertised subnet
route** (the device looks healthy while nothing routes), and set **split DNS**
for your domain to the k8s-gateway LoadBalancer IP (without it, internal names
resolve at home but not on cellular). Both are in
`clusters/lab/platform/tailscale/SEALING.md`.

Tailscale + DNS-01 together is a strong story: fully remotely accessible,
entirely closed inbound firewall.

### Optional, later — Headscale

Headscale is an open-source reimplementation of Tailscale's coordination
server. Self-hosting it means the control plane is yours and the network does
not depend on Tailscale's SaaS. It is a genuinely strong resume item.

**Treat it as strictly optional and do it last.** It is the component most
likely to break remote access, and losing remote access to a headless box is
the one failure that means physically walking over to it. Get everything else
stable on hosted Tailscale first; migrate only if you want to.

**Phase 4 done when:** an internal hostname serves a valid public cert, and with
your Mac off home WiFi (cellular hotspot) + Tailscale connected,
`kubectl get nodes` works.

---

## Phase 5 — Observability

`kube-prometheus-stack`, trimmed for 16GB: 7-day retention, 30s scrape, explicit
memory limits on Prometheus, default alert rules pruned.

ServiceMonitors for Cilium/Hubble, Rook-Ceph (enable the mgr prometheus module),
and ArgoCD. Import the community Ceph and Cilium Grafana dashboards.

Watch **`etcd_disk_wal_fsync_duration_seconds`** specifically. It's where a
single-node cluster on consumer storage starts misbehaving, and knowing to look
there is exactly the kind of thing this project should teach.

**Phase 5 done when:** Ceph and Cilium dashboards are populated, and downing an
OSD deliberately fires an alert.

---

## Phase 6 — AI workload layer (CPU)

No GPU, so the demonstration is the *platform*, not throughput.

- **Ollama** with a Ceph RBD PVC for models, serving a small quantized model
  (Qwen3 4B or Llama 3.2 3B, Q4). A few tokens/sec — enough to be real.
  **Open WebUI** in front, via Gateway API, reachable over Tailscale.
  Chosen over a CPU vLLM build for reliability; note vLLM as the GPU path in
  `docs/decisions.md`.
- **MLflow** — tracking server, artifacts in the Ceph RGW bucket, metadata in
  Postgres via **CloudNativePG**. This closes the loop: Ceph holds real ML
  artifacts rather than being decoration.
- **Node Feature Discovery** — installs clean, surfaces CPU features, and is the
  same component GPU clusters use. Signals you know the GPU path without the
  hardware.
- **ResourceQuota + PriorityClass** to demo scheduling and preemption. Cheap in
  RAM, high in platform-thinking signal.
- **Velero** → RGW bucket, with a copy synced off-box.
- **Skip KServe/Knative** — too heavy here. Say so explicitly in the decision log
  rather than silently omitting it.

**Phase 6 done when:** Open WebUI answers a prompt end-to-end, an MLflow run's
artifact is visible in the Ceph bucket, and a Velero backup restores into a fresh
namespace.

---

## Phase 7 — OpenStack (Kolla-Ansible in a KVM guest)

### 7a. Host virtualization

```bash
sudo apt-get install -y qemu-kvm libvirt-daemon-system virtinst
cat /sys/module/kvm_intel/parameters/nested    # must print Y
```

**Wired:** create a Linux **bridge (br0)** over the ethernet NIC so the guest
sits directly on the LAN and floating IPs are ordinary LAN addresses.

**WiFi:** bridging is impossible over 802.11, so give the guest two virtual NICs
(NAT for management, an isolated network for `neutron_external_interface`) and
reach floating IPs by host route or a Tailscale subnet route from inside the
guest. Full recipe in `docs/WIFI.md`. The Phase 7 milestone is unaffected.

### 7b. Mode-switch script

`scripts/openstack-mode.sh` — commit it; it's a good artifact in itself:

- scale Prometheus, Hubble relay/UI, ArgoCD, RGW to 0 replicas
- `ceph config set osd osd_memory_target 1073741824`
- `virsh start openstack`

`scripts/k8s-mode.sh` reverses it. ~20 seconds, no reboot, cluster stays up.

### 7c. The guest

Ubuntu 24.04 cloud image, 8 vCPU (overcommit is fine), ~7.5GiB RAM, 80GiB disk on
`lv_libvirt`.

Kolla-Ansible all-in-one:

- **Enable:** keystone, glance, nova, neutron (OVN), placement, horizon
- **Disable:** cinder, heat, octavia, barbican, swift, ceilometer/gnocchi
- `nova_compute_virt_type: kvm` for nested KVM; fall back to `qemu` if unstable

### 7d. "Compute kit running" — definition of done

1. Upload a Cirros image to Glance
2. Create a flavor
3. Create tenant network + router + floating IP pool
4. Boot an instance
5. Ping the floating IP **from the host** and SSH into the guest

### 7e. Then the actual learning

Read the nova-scheduler logs for that boot. Inspect Placement directly:

```bash
openstack resource provider list
openstack resource provider inventory list <uuid>
openstack allocation show <instance-uuid>
```

Change allocation ratios. Deliberately cause a scheduling failure by
over-requesting. Understanding how Placement claims resources is the transferable
idea — it's the same problem Kubernetes solves differently, and being able to
compare the two is the entire point of building both.

---

## Phase 8 — Packaging it

The system is half the deliverable.

- **README** — Mermaid architecture diagram + the RAM budget table.
- **`docs/decisions.md`** — Cilium over Calico; kube-proxy replacement; `size: 2`
  with `failureDomain: osd`; single mon; Tailscale over Twingate and port-forwarded WireGuard;
  Ollama over vLLM; OpenStack in a guest rather than dual-boot. Reasoned
  tradeoffs under a hard constraint read far better than a component list.
- **Screenshots** — Hubble flow map, Grafana Ceph dashboard, ArgoCD app tree,
  Horizon with a running instance.
- **A writeup** — *"Kubernetes, Ceph, and OpenStack on one 16GB box: what I had
  to tune and why."* The constraint is the story.
- **`make rebuild`** — wipe and restore the cluster from Git in one command. The
  most impressive thing you can demo, and it forces the GitOps work to be honest.

---

## Verification summary

| Phase | Check |
|---|---|
| 0 | no swap; `lsblk -f` shows p4/p5 blank; reachable with lid shut |
| 1 | node Ready; `cilium status` green; **no kube-proxy pods**; LB Service answers from your Mac |
| 2 | ArgoCD self-managed and Synced; deleted resources self-heal |
| 3 | `HEALTH_OK`, 2 OSDs; PVC binds and writes; S3 put+get works |
| 4 | valid public cert on an internal name; `kubectl` works over cellular + Tailscale |
| 5 | Ceph/Cilium dashboards populated; downing an OSD fires an alert |
| 6 | Open WebUI answers; MLflow artifact lands in Ceph; Velero restore succeeds |
| 7 | Cirros boots; floating IP pings from host; Placement shows the claim |
| 8 | `make rebuild` reaches full green with no manual `kubectl apply` |

---

## Known risks

- **Rook ignores dirty devices.** Residual FS/LVM signature on p4/p5 → OSDs never
  appear, no error. Zap first; verify with `lsblk -f`.
- **Cilium without kube-proxy needs `k8sServiceHost`/`k8sServicePort`.** Omitting
  them is a chicken-and-egg hang that looks like a broken CNI.
- **Single mon is a SPOF.** Accepted deliberately; back the mon store up to RGW.
- **Consumer SSD + etcd.** Watch fsync latency; NVMe is usually fine, SATA may
  not be.
- **Thermals.** Sustained load throttles small chassis. Check `turbostat` under
  load.
- **Version drift.** `apt-mark hold` on kube*; upgrade one minor at a time, as
  its own deliberate exercise.
- **Battery as UPS** (laptop chassis) — a genuine advantage for Ceph. Configure a
  graceful shutdown hook at low battery so OSDs stop cleanly.
