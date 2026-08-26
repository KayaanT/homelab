# Networking on a box with no ethernet port

## Why wired is required

Two things need it. Neither is what you might assume.

**Cilium L2 announcements.** LoadBalancer IPs work by having the node answer ARP
for addresses that aren't its own. Consumer access points handle this
inconsistently — many run proxy-ARP or client isolation and silently drop the
replies. The Service gets an IP and simply never responds.

**Bridged networking for the OpenStack guest.** This one is a hard limit, not a
misconfiguration. An 802.11 data frame in client mode carries three MAC address
fields, so a station cannot transmit a frame with a source MAC other than its
own. A Linux bridge fundamentally requires that. There is no config that fixes
it; `parprouted`/`ebtables` workarounds are fragile and route-only.

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
