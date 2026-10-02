#!/usr/bin/env bash
# mkdisk.sh <rootfs> <out.vhd> [size-GB]: PlangOS's data disk — /home/plang on a disk of its own, so a new
# PlangOS image never touches it. An ext4 filesystem labelled plangos-data (what /etc/fstab mounts on
# /home/plang), seeded with the image's /home/plang (rootfs/home/plang), everything owned by plang
# (10001:10001, as mktar.py makes /home/plang), wrapped as a dynamic VHD (only what's written takes space).
# Made once; start.ps1 attaches it (`wsl --mount --vhd --bare`). Needs: mkfs.ext4, debugfs, node.
set -euo pipefail
ROOTFS="$1"; OUT="$2"; GB="${3:-32}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SEED="$ROOTFS/home/plang"
[ -d "$SEED" ] || { echo "no $SEED" >&2; exit 1; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
raw="$work/data.img"
truncate -s "${GB}G" "$raw"
# -d: the seed's files; the root directory as /home/plang is in the image (plang's, 0750)
mkfs.ext4 -q -F -L plangos-data -E root_owner=10001:10001 -d "$SEED" "$raw"
# every file the seed put there is plang's (mkfs.ext4 -d keeps the builder's own uid)
cmds="$work/owner.cmds"
( cd "$SEED" && find . -mindepth 1 -printf '%P\n' ) | while read -r p; do
  printf 'set_inode_field "/%s" uid 10001\nset_inode_field "/%s" gid 10001\n' "$p" "$p"
done > "$cmds"
printf 'set_inode_field / mode 040750\n' >> "$cmds"
debugfs -w -f "$cmds" "$raw" >/dev/null 2>&1
e2fsck -fn "$raw" >/dev/null   # a clean filesystem, or this stops here
node "$HERE/vhd.js" "$raw" "$OUT"
