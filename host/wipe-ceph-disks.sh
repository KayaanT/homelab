#!/usr/bin/env bash
# DESTRUCTIVE. Wipes the partitions Rook-Ceph will claim as OSDs.
# Rook silently skips any device carrying a filesystem or LVM signature -
# it presents as "OSDs never appear" with no error. This prevents that.
set -euo pipefail

DEVICES=("${@:-/dev/nvme0n1p4 /dev/nvme0n1p5}")
read -r -a DEVICES <<< "${DEVICES[*]}"

echo "About to DESTROY ALL DATA on:"
printf '  %s\n' "${DEVICES[@]}"
echo
lsblk -f "${DEVICES[@]}" 2>/dev/null || true
echo
for d in "${DEVICES[@]}"; do
  if findmnt -S "$d" >/dev/null 2>&1; then
    echo "REFUSING: $d is currently mounted." >&2; exit 1
  fi
done
read -rp 'Type WIPE to continue: ' confirm
[[ "$confirm" == "WIPE" ]] || { echo "Aborted."; exit 1; }

for d in "${DEVICES[@]}"; do
  echo "==> wiping $d"
  sudo wipefs -a "$d"
  sudo dd if=/dev/zero of="$d" bs=1M count=100 oflag=direct,dsync status=none
  sudo blkdiscard -f "$d" 2>/dev/null || echo "    (blkdiscard unsupported, skipped)"
done

echo
echo "Result - FSTYPE column must be empty for each device:"
lsblk -f "${DEVICES[@]}"
