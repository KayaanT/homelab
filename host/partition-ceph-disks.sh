#!/usr/bin/env bash
# Create the Ceph OSD partitions in FREE SPACE at the end of the disk, then
# wipe them so Rook will claim them.
#
# This exists so you do not have to get the full layout right in the Ubuntu
# installer. Install with EFI + /boot + LVM only, leave the rest of the disk
# unallocated, and run this afterwards.
#
# It only ever writes to unallocated space. It never resizes, moves, or deletes
# an existing partition, so it cannot damage the installed system.
#
#   sudo ./host/partition-ceph-disks.sh                 # 2 OSDs, split free space
#   sudo ./host/partition-ceph-disks.sh /dev/nvme0n1 2 120G
set -euo pipefail

DISK="${1:-/dev/nvme0n1}"
COUNT="${2:-2}"
SIZE="${3:-auto}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "$DISK" ]]  || die "$DISK is not a block device."
command -v sgdisk >/dev/null || die "sgdisk missing: apt install gdisk"

log "Current layout of $DISK"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS "$DISK"
echo

# --- work out the free space ------------------------------------------------
SECTOR=$(blockdev --getss "$DISK")
FIRST=$(sgdisk -f "$DISK")          # first aligned sector in the largest free block
LAST=$(sgdisk -E "$DISK")           # last usable sector
(( LAST > FIRST )) || die "No free space on $DISK. Nothing safe to do here."

FREE_SECTORS=$(( LAST - FIRST + 1 ))
FREE_GIB=$(( FREE_SECTORS * SECTOR / 1024 / 1024 / 1024 ))
log "Free space: ${FREE_GIB} GiB (sectors ${FIRST}-${LAST})"

if [[ "$SIZE" == "auto" ]]; then
  # Split evenly, leaving 1 GiB of slack so the last partition always fits.
  PER_GIB=$(( (FREE_GIB - 1) / COUNT ))
  (( PER_GIB >= 20 )) || die "Only ${PER_GIB} GiB per OSD. Too small to be useful."
  SIZE="${PER_GIB}G"
fi

# --- confirm ----------------------------------------------------------------
EXISTING=$(sgdisk -p "$DISK" | awk '/^ +[0-9]+/ {n=$1} END {print n+0}')
echo
echo "Plan:"
echo "  disk            $DISK"
echo "  existing parts  ${EXISTING} (untouched)"
echo "  will create     ${COUNT} partitions of ${SIZE} each, in free space"
echo "  then wipe them  (they must carry no filesystem signature for Rook)"
echo
read -rp 'Type CREATE to proceed: ' confirm
[[ "$confirm" == "CREATE" ]] || die "Aborted."

# --- create -----------------------------------------------------------------
NEW=()
for i in $(seq 0 $((COUNT - 1))); do
  log "Creating ceph-osd-${i} (${SIZE})"
  # 0:0:+SIZE -> next free partition number, first aligned free sector, SIZE big.
  # sgdisk picks the largest free block itself, so existing partitions are safe.
  sgdisk -n "0:0:+${SIZE}" -t "0:8300" -c "0:ceph-osd-${i}" "$DISK" >/dev/null
done

partprobe "$DISK"; udevadm settle; sleep 2

# Collect what we just made, by the labels we set.
mapfile -t NEW < <(lsblk -ln -o PATH,PARTLABEL "$DISK" | awk '$2 ~ /^ceph-osd-/ {print $1}')
(( ${#NEW[@]} == COUNT )) || die "Expected ${COUNT} new partitions, found ${#NEW[@]}. Inspect with: sgdisk -p $DISK"

# --- wipe -------------------------------------------------------------------
# Rook SILENTLY skips any device carrying a filesystem or LVM signature. This is
# the single most common Rook-on-bare-metal failure and it logs nothing useful.
for p in "${NEW[@]}"; do
  findmnt -S "$p" >/dev/null 2>&1 && die "$p is mounted. Refusing."
  log "Wiping $p"
  wipefs -a "$p" >/dev/null
  dd if=/dev/zero of="$p" bs=1M count=100 oflag=direct,dsync status=none
  blkdiscard -f "$p" 2>/dev/null || true
done

echo
log "Result — FSTYPE must be empty for the ceph-osd partitions"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINTS "$DISK"
echo
echo "Put these in clusters/lab/infra/rook-ceph-cluster/manifests/cluster.yaml:"
for p in "${NEW[@]}"; do echo "          - name: \"$(basename "$p")\""; done
