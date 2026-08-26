# Networking on a box with no ethernet port

## Short version: WiFi is fine to start

You do **not** need the ethernet adapter to begin. Phases -1 through 6 all work
over WiFi — installing Ubuntu, kubeadm, Cilium, ArgoCD, Rook-Ceph, cert-manager,
Tailscale, observability, and the AI workloads. Plug the adapter in when it
arrives; nothing gets rebuilt.

| Phase | Works on WiFi? |
|---|---|
| -1 Install Ubuntu | Yes — the server installer connects to WPA2 |
| 0 Host prep | Yes |
| 1 kubeadm + Cilium | Yes. Cilium installs and routes normally; only the LoadBalancer smoke test at the end may not answer |
| 2 ArgoCD | Yes |
| 3 Rook-Ceph | Yes — replication is local disk to local disk |
| 4 cert-manager, Tailscale | Yes. The k8s-gateway DNS app needs a LoadBalancer IP, so leave it unsynced until the adapter arrives |
| 5 Observability | Yes — reach Grafana over Tailscale |
| 6 AI workloads | Yes — reach Open WebUI over Tailscale |
| 7 OpenStack | Yes, with NAT + routed floating IPs instead of a bridge — see below |
| 8 Writeup | Yes |

**Test L2 announcements before assuming you need the adapter.** Some access
points forward gratuitous ARP without complaint:

```bash
kubectl create deploy nginx --image=nginx
kubectl expose deploy nginx --type=LoadBalancer --port=80
kubectl get svc nginx                      # note the EXTERNAL-IP
curl -m5 http://<EXTERNAL-IP>              # from your Mac, on the same LAN
```

If that returns nginx's page, your AP cooperates and the adapter is only needed
for Phase 7.

Either way, **Tailscale makes access a non-issue**: once the operator is up you
reach every service by its tailnet name, at home and on cellular, whether or not
LAN LoadBalancer IPs work. The LB IPs are there to learn the pattern, not to be
the access path.

## Why wired is required eventually

Two things need it. Neither is what you might assume.

**Cilium L2 announcements.** LoadBalancer IPs work by having the node answer ARP
for addresses that aren't its own. Consumer access points handle this
inconsistently — many run proxy-ARP or client isolation and silently drop the
replies. The Service gets an IP and simply never responds.

**Bridged networking for the OpenStack guest.** An 802.11 data frame in client
mode carries three MAC address fields, so a station cannot transmit a frame with
a source MAC other than its own, and a Linux bridge fundamentally requires that.
This is a hard limit of the standard.

It does **not** block OpenStack — see "OpenStack without a bridge" below. What
you lose is floating IPs appearing as first-class addresses on the home LAN.

**Ceph and etcd are *not* reasons.** On a single node, Ceph replicates between
two OSDs on the same local disk and etcd fsyncs to local storage. Neither
touches the network. (An earlier draft of this plan claimed otherwise.)

## The adapter

Any USB3 or USB-C gigabit adapter with a Realtek RTL8153 or ASIX AX88179
chipset — both are in-kernel and need no driver. Anker, UGREEN, Cable Matters,
and Amazon Basics all ship one of the two. **Avoid USB 2.0 adapters** (100Mbps
ceiling) and no-name chipsets.

## USB NIC gotchas

### Interface naming

USB NICs get a MAC-derived name like `enx00e04c680125`, not `eth0` or `enp2s0`.
This is stable across reboots, which is what you want. Find it with:

```bash
ip -br link
```

The `NIC_REGEX` in `homelab.env` defaults to `^en.*`, which matches both `enx*`
and `enp*` — no change needed.

### USB autosuspend will drop your link

This is the one that bites, and it bites *hours* later on an idle headless box.
The kernel power-manages idle USB devices, and many ethernet adapters do not
resume cleanly.

```bash
# disable autosuspend for USB network adapters
cat <<'RULE' | sudo tee /etc/udev/rules.d/50-usb-nic-nopower.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="00", TEST=="power/control", ATTR{power/control}="on"
RULE
sudo udevadm control --reload && sudo udevadm trigger
```

Verify after a reboot:

```bash
cat /sys/bus/usb/devices/*/power/control   # should be 'on', not 'auto'
```

### Boot ordering

USB devices enumerate later than PCI ones. With `optional: false` on the wired
interface, systemd-networkd waits for it, which is what you want — but if the
adapter is ever unplugged the box will hang for ~2 minutes at boot before
continuing. That is the correct trade for a headless machine.

## Recommended netplan: wired primary, WiFi fallback

Both interfaces up, wired preferred by route metric. If the USB NIC dies or is
knocked out of its port, the box stays reachable over WiFi instead of becoming a
machine you have to carry a monitor to.

`/etc/netplan/50-homelab.yaml`:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enx00e04c680125:          # your USB NIC, from `ip -br link`
      dhcp4: true
      dhcp4-overrides:
        route-metric: 100     # lower metric = preferred
      optional: false
  wifis:
    wlp0s20f3:                # your WiFi interface
      dhcp4: true
      dhcp4-overrides:
        route-metric: 600     # fallback only
      optional: true          # never block boot on WiFi
      access-points:
        "YOUR_SSID":
          password: "YOUR_PSK"
```

```bash
sudo chmod 600 /etc/netplan/50-homelab.yaml
sudo netplan apply
ip route            # default via the wired NIC, metric 100
```

Set a DHCP reservation for **both** MACs on the router.

## Verify

```bash
ip -br addr                              # both interfaces have addresses
ip route | head -2                       # wired default route wins
sudo ethtool enx... | grep Speed         # 1000Mb/s
# pull the USB NIC, wait 10s - SSH should survive on the WiFi address
```

## If you decide not to buy the adapter

The plan still works, with two changes:

1. Drop `l2announcements` from the Cilium values and delete
   `clusters/lab/infra/cilium/lb-ipam.yaml`, plus the `platform/dns` app.
   Expose services as tailnet devices instead, via `tailscale.com/expose: "true"`
   on the Service or the `tailscale` ingressClass. MagicDNS names then work
   identically at home and remotely.
2. Run the OpenStack guest on libvirt's NAT network and install Tailscale
   *inside* the guest, advertising the OpenStack floating-IP range as a subnet
   route.

You lose hands-on LoadBalancer/ARP, which is a core Kubernetes concept worth
having done at least once. That is the actual cost — not capability.


## OpenStack without a bridge

The guest gets two virtual NICs. Inside the guest they are ordinary virtio
ethernet devices, so the host's WiFi is irrelevant to them:

```bash
virt-install ... \
  --network network=default \                      # NIC1: NAT, management/SSH
  --network network=openstack-ext,model=virtio      # NIC2: neutron_external_interface
```

Create the isolated network once on the host:

```bash
cat > /tmp/os-ext.xml <<'XML'
<network>
  <name>openstack-ext</name>
  <bridge name='virbr-osext' stp='on' delay='0'/>
</network>
XML
sudo virsh net-define /tmp/os-ext.xml
sudo virsh net-autostart openstack-ext && sudo virsh net-start openstack-ext
```

No `<forward>` and no `<ip>`: Neutron wants a raw L2 segment with no address of
its own, and will attach it to `br-ex` itself.

In Kolla's `globals.yml`:

```yaml
network_interface: "ens3"              # NIC1, has the NAT address
neutron_external_interface: "ens4"     # NIC2, MUST have no IP configured
```

Then reach the floating IPs. Either add a host route:

```bash
sudo ip route add 172.24.4.0/24 via <guest-NAT-address>
# in the guest: sysctl -w net.ipv4.ip_forward=1
```

…or, better, install Tailscale **inside the guest** and advertise the range:

```bash
sudo tailscale up --advertise-routes=172.24.4.0/24 --accept-dns=false
```

Approve the route in the admin console and OpenStack floating IPs become
reachable from your Mac and phone anywhere — which the bridge approach could
never do, since it only ever worked on the home LAN.

**What you actually lose without a bridge:** floating IPs are not pingable from
an arbitrary LAN device without a route. The Phase 7 milestone — boot a Cirros
instance, assign a floating IP, ping it, SSH in, inspect Placement allocations —
is unaffected.


## Intel Wireless-AC 9560 — power management will bite you

The 9560 is a CNVi part driven by `iwlwifi`, in-kernel since ~4.14 with firmware
from `linux-firmware`. It works on Ubuntu with no setup.

**But its default power saving makes a headless box unreliable.** The symptom is
distinctive and easy to misdiagnose: SSH and Prometheus scrapes hang for several
seconds after any idle period, latency looks erratic, and nothing in the logs
explains it. The radio is entering a low-power state and taking too long to come
back.

```bash
cat <<'EOF' | sudo tee /etc/modprobe.d/iwlwifi-noposwer.conf
options iwlwifi power_save=0 d0i3_disable=1 uapsd_disable=1
options iwlmvm power_scheme=1
EOF
sudo update-initramfs -u
sudo reboot
```

Verify:

```bash
iw dev wlp0s20f3 get power_save     # should print 'Power save: off'
cat /sys/module/iwlwifi/parameters/power_save   # 0
```

`power_scheme=1` is the "always active" setting. On a machine running on mains
power that is what you want; battery life is irrelevant for a server.
