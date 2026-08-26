#!/usr/bin/env bash
# Phase 0 — host preparation. Run on the homelab box as a sudo-capable user.
# Idempotent: safe to re-run.
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

if [[ $EUID -eq 0 ]]; then echo "Run as a normal user with sudo, not as root." >&2; exit 1; fi

# --- laptop chassis only: ignore the lid switch ------------------------------
if [[ -d /proc/acpi/button/lid ]]; then
  log "Laptop lid detected - configuring logind to ignore it"
  sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/;
               s/^#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/;
               s/^#\?HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
  sudo systemctl restart systemd-logind
fi

log "Masking sleep targets"
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

log "Disabling swap (kubelet requires this)"
sudo swapoff -a
sudo sed -i '/\sswap\s/ s/^\([^#]\)/#\1/' /etc/fstab

log "Loading kernel modules"
printf 'overlay\nbr_netfilter\n' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
sudo modprobe overlay
sudo modprobe br_netfilter

log "Applying sysctls"
sudo tee /etc/sysctl.d/99-k8s.conf >/dev/null <<'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sudo sysctl --system >/dev/null

log "Installing containerd + chrony"
sudo apt-get update -qq
sudo apt-get install -y -qq containerd chrony

log "Configuring containerd for the systemd cgroup driver"
# Regenerating the default config clears the disabled_plugins=["cri"] that some
# distro packages ship with, and works across containerd config schema versions.
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Verify rather than assume the sed matched. A silently-unset cgroup driver
# produces kubelet failures that look like anything but a config problem:
# pods stuck in ContainerCreating, and cgroup errors buried in journalctl.
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
  echo "ERROR: SystemdCgroup was not set in /etc/containerd/config.toml." >&2
  echo "The config schema may have changed. Find the runc options block:" >&2
  grep -n 'runtimes.runc' /etc/containerd/config.toml >&2 || true
  echo "and set SystemdCgroup = true under its [...options] table." >&2
  exit 1
fi

sudo systemctl restart containerd
sudo systemctl enable --now containerd chrony

log "Verifying"
echo "  swap:        $(free -h | awk '/Swap/ {print $2}')  (must be 0B)"
echo "  containerd:  $(containerd --version | awk '{print $3}')  ($(systemctl is-active containerd))"
echo "  config ver:  $(grep -m1 '^version' /etc/containerd/config.toml)"
echo "  SystemdCgroup: set in $(grep -c 'SystemdCgroup = true' /etc/containerd/config.toml) place(s)"
echo "  kernel:      $(uname -r)"
echo
echo "Next: review 'lsblk -f', then run host/wipe-ceph-disks.sh"
