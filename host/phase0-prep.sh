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
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable --now containerd chrony

log "Verifying"
echo "  swap:        $(free -h | awk '/Swap/ {print $2}')  (must be 0B)"
echo "  containerd:  $(systemctl is-active containerd)"
echo "  SystemdCgroup: $(grep -c 'SystemdCgroup = true' /etc/containerd/config.toml) occurrence(s)"
echo
echo "Next: review 'lsblk -f', then run host/wipe-ceph-disks.sh"
