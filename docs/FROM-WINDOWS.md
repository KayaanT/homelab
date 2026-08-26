# Phase -1 — Windows to Ubuntu Server

The box ships with Windows. This wipes it. Everything here happens at the
keyboard, before `host/phase0-prep.sh`.

## 1. Before you wipe

- **Back up anything you care about.** This is destructive and total.
- **Note the WiFi chipset**: Device Manager → Network adapters. An Intel AX201 /
  AX211 (typical for 11th-gen) is supported in-kernel and Just Works. A Realtek
  RTL8852/8821 may need a DKMS driver built after install — check before you
  commit, because a headless box with no working WiFi and no ethernet port is a
  box you can only reach by carrying a monitor to it.
- **Look again for an ethernet port.** Some thin laptops hide one behind a drop
  jaw flap. Also check for USB-C / Thunderbolt — any USB-C dock or a $15 USB3
  gigabit adapter solves the problems in `docs/WIFI.md`.

## 2. BIOS settings — the part that actually bites

Reboot into firmware setup (usually F2, F10, or Del at the vendor splash).

| Setting | Set to | Why |
|---|---|---|
| **SATA/NVMe mode: Intel RST / RAID** | **AHCI** | The single most common failure. Many OEM laptops ship the NVMe in RST mode and the Ubuntu installer then reports **"no disks found"** — the drive is invisible, not broken. |
| **Intel VT-x / Virtualization Technology** | **Enabled** | Required for Phase 7 (KVM). Frequently off by default on OEM machines. |
| **VT-d / IOMMU** | Enabled | Needed for any device passthrough later. |
| Secure Boot | Leave **on** | Ubuntu is signed and boots fine. Only disable if a third-party WiFi driver refuses to load and MOK enrollment is more hassle than it's worth. |
| Boot order | USB first | So the installer comes up. |
| **"Fast Boot" / "Quiet Boot"** | Disabled | Makes the USB device selectable and shows POST errors. |

Note the SATA mode change **before** installing. Switching it after Linux is
installed is recoverable; switching it while Windows is still the boot OS makes
Windows unbootable (irrelevant here, since it's going).

## 3. Make the installer

On the Windows box, before wiping:

1. Download **Ubuntu Server 24.04.x LTS** (not Desktop) from ubuntu.com.

   **Why 24.04 and not 26.04:** the newer LTS has a better kernel, but every
   guide, and more importantly Kolla-Ansible's supported-base-distro matrix and
   the Rook/Ceph docs, target 24.04. Being on the newest LTS means hitting bugs
   nobody has written about yet — fine when learning one tool, painful when
   learning five at once. Check Kolla's release notes for your target OpenStack
   version before choosing 26.04.
2. Write it with [Rufus](https://rufus.ie): partition scheme **GPT**, target
   **UEFI**, and accept "DD image mode" if prompted.
3. Reboot, tap the boot-menu key (F12 on most), pick the USB device.

## 4. During the install

- **Connect WiFi in the installer.** The Ubuntu Server installer supports WPA2 —
  it will ask. Do it here; configuring it afterward from a console is worse.
- **Manual partitioning — but only three partitions.** You do *not* need to
  create the Ceph partitions here. Create what's needed to boot, then stop and
  leave the rest of the disk as **free space**:

```
nvme0n1p1   1 GiB    EFI System Partition
nvme0n1p2   2 GiB    /boot            ext4
nvme0n1p3 200 GiB    LVM PV -> vg0
                       lv_root    110 GiB  /                        ext4
                       lv_libvirt  80 GiB  /var/lib/libvirt/images  ext4
            ~240 GiB  leave UNALLOCATED   <- Ceph OSDs, created post-install
```

  After the install, `host/partition-ceph-disks.sh` carves the OSD partitions
  out of that free space and wipes them. It only ever writes to unallocated
  space — it never resizes, moves, or deletes an existing partition, so it
  cannot damage the installed system.

  This is deliberately easier than getting all five right in the installer.
  Subiquity's "leave unformatted" flow is the fiddliest part of the whole
  install, and skipping it costs nothing.

  **Do not use "Use an entire disk".** Guided mode consumes the whole disk for
  the LVM PV, and reclaiming space afterwards means shrinking a physical volume
  and then the partition under it — genuinely risky, and needing live media for
  the root filesystem. Leaving free space up front avoids all of that.

- **No swap partition.** If the installer insists, make it and
  `host/phase0-prep.sh` will disable it.
- **Tick "Install OpenSSH server".** Non-negotiable — this is the last time you
  will be sitting at this keyboard.
- Import your SSH key from GitHub when offered (`gh:KayaanT`), or paste it.
- **Skip every snap** on the featured-server-snaps screen.

## 5. First boot

```bash
ip -br addr                 # confirm WiFi has an address
sudo apt update && sudo apt full-upgrade -y
hostnamectl set-hostname homelab
```

Set a **DHCP reservation** on your router for this MAC so the IP never moves,
rather than a static netplan address — it survives router changes better and
avoids conflicts.

Persist the WiFi config so it survives reboots headless
(`/etc/netplan/50-cloud-init.yaml`):

```yaml
network:
  version: 2
  wifis:
    wlp0s20f3:                 # check `ip -br link`
      dhcp4: true
      optional: false          # boot waits for the network - you want this
      access-points:
        "YOUR_SSID":
          password: "YOUR_PSK"
```

```bash
sudo chmod 600 /etc/netplan/50-cloud-init.yaml
sudo netplan apply
```

`optional: false` matters on a headless box: without it, systemd continues boot
before WiFi associates, and services that bind to the node IP can come up wrong.

## 6. Verify before moving on

```bash
ssh homelab@<ip>                             # from your Mac, key auth
lsblk -f                                     # p1-p3 present, free space at the end
cat /sys/module/kvm_intel/parameters/nested  # Y  (VT-x is on)
ping -c3 1.1.1.1
```

Then:

```bash
git clone https://github.com/KayaanT/homelab && cd homelab
./host/phase0-prep.sh
sudo ./host/partition-ceph-disks.sh          # creates + wipes the OSD partitions
```
