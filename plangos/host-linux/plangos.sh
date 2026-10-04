#!/bin/bash
# PlangOS from an unpacked image ($PLANGOS_ROOT, default ./rootfs), as wsl.exe starts it on Windows: its screen's frames
# on stdout, the host's input on stdin. Needs run-local.sh (user namespaces, no root) and a bash at
# /home/plang/.ct/bash in the rootfs (PlangOS has no shell; tools/video/harness-setup.sh puts one there).
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${PLANGOS_ROOT:-$HERE/rootfs}"
exec "${RUN_LOCAL:-$HERE/../run-local.sh}" "$ROOT" /home/plang/.ct/bash -c 'cd /home/plang && exec /opt/plang/plang system/plangos/Screen 2> /home/plang/.ct/err'
