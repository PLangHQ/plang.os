# Attack surface — PlangOS v1 image

Measured on the build of 2026-09-28 (`checks.py`: 14/14 passed).

- [x] **Base** — no base image. 220 Debian 13 packages from snapshot.debian.org `20260928T000000Z`, each pinned by sha256 in `plangos/packages.lock`; the archive keyring is pinned by sha256 in `build.sh`. 185 packages are unpacked; the list ships in `/opt/plang/os-packages.txt`.
- [x] **Packages** — each root is justified in `packages.conf`; everything else is Chromium's or .NET's dependency closure. The deny-list (systemd, dbus, PAM, debconf, Mesa, admin CLIs) is justified line by line.
- [x] **Binaries on PATH** — **0**. `/usr/bin` and `/usr/sbin` are empty. The only executables are `/opt/plang/plang` and Chromium's in `/usr/lib/chromium/`.
- [x] **Shell** — absent. No `sh`, `bash`, `dash` or `busybox`.
- [x] **Package manager** — absent. No `dpkg`, no `apt`, no dpkg database.
- [x] **Setuid/setgid** — none. `mktar.py` refuses to write the tarball if one appears, and no unpacked `.deb` contains one (checked from the package listings).
- [ ] **Open ports** — none are opened by the image. To be measured in WSL (`ss` isn't in the image; check from the host side).
- [x] **Capabilities** — nothing runs as root: no boot command, no init, no daemons. plang runs as uid 10001.
- [~] **Filesystem** — everything outside `/home/plang` is owned by root and not world-writable (`/tmp`, `/var/tmp` sticky). Not read-only: WSL mounts the distro disk read-write.
- [x] **User** — `plang`, uid/gid 10001. No `/etc/shadow`, so no passwords exist.
- [x] **Secrets** — none baked in. plang creates its identity on first run in `/home/plang/.db`.
- [x] **CVEs** — grype 0.119.0: 4 Critical, 78 High. Sources: Playwright's Node, PLang NuGet packages (fixable by bumps), and Debian (no fixes yet). See `cves.md`.
- [ ] **Signature** — the manifest has sha256 + size. Signing waits on PLang's signature format being usable by host plang.
- [x] **SBOM** — syft 1.52.0 SPDX JSON (`plangos-amd64.spdx.json`, published next to the image): 189 deb, 117 .NET, 76 npm (Playwright's driver), 2 binaries.

## Seal (WSL)
`/etc/wsl.conf`: `[interop] enabled=false, appendWindowsPath=false`, `[automount] enabled=false, mountFsTab=false`, `[user] default=plang`. The container can't start Windows programs or see `/mnt/c`.

**Limit:** wsl.conf is enforced by WSL's init reading a file inside the distro. It holds because `plang` can't become root (no setuid, no su/sudo, no shell). A kernel exploit inside the WSL VM would break it. Every WSL2 distro shares one VM and kernel.

## Chromium sandbox
Works unprivileged through user namespaces, with no setuid `chrome-sandbox`. Tested with `run-local.sh`: headless Chromium as uid 10001 rendered a page without `--no-sandbox`. Chromium refuses to start without a usable sandbox, which is what happened under a plain chroot.
