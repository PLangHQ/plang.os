#!/usr/bin/env bash
# Run a command inside a built PlangOS rootfs on a Linux build machine, as the
# plang user (uid 10001), with /proc and /dev mounted the way WSL provides them.
# No root needed: user + mount + pid namespaces.
#
#   plangos/run-local.sh <rootfs-dir> <command> [args...]
#
# The rootfs becomes the real root (pivot_root, like WSL or a container runtime),
# not a chroot: the kernel refuses to create user namespaces from inside a chroot,
# and Chromium's sandbox needs them.
#
# For testing only. The real runtime is WSL (Windows).
set -euo pipefail
ROOT="$(cd "$1" && pwd)"; shift
[ "$#" -gt 0 ] || { echo "usage: run-local.sh <rootfs-dir> <command> [args...]" >&2; exit 2; }

if [ "${_PLANGOS_INNER:-}" != 1 ]; then
  # outer: become root in a new user/mount/pid namespace, with a fresh /proc
  exec env _PLANGOS_INNER=1 unshare -r -m -p -f --mount-proc "$0" "$ROOT" "$@"
fi

# inner (uid 0 in our own namespace)
UMOUNT="$(command -v umount || echo /bin/umount)"; UNSHARE="$(command -v unshare)"
mount --make-rprivate /
mount --bind "$ROOT" "$ROOT"                       # pivot_root needs a mount point
mount --rbind /proc "$ROOT/proc"
mount --rbind /dev  "$ROOT/dev"
mount -t tmpfs -o mode=1777 tmpfs "$ROOT/tmp"
mount -t tmpfs tmpfs "$ROOT/run"
# the host's unshare, borrowed to drop to uid 10001 after the pivot (PlangOS has none)
touch "$ROOT/run/unshare" && mount --bind "$UNSHARE" "$ROOT/run/unshare"
mkdir "$ROOT/run/oldroot"

cd "$ROOT"
pivot_root . run/oldroot
"/run/oldroot$UMOUNT" -l /run/oldroot   # host's umount, reached through the old root

# clean environment (no env binary in PlangOS, so bash does it)
for v in $(compgen -e); do unset "$v" 2>/dev/null || true; done
export HOME=/home/plang PATH=/usr/bin USER=plang
exec /run/unshare -U --map-user=10001 --map-group=10001 --wd=/home/plang "$@"
