# Tradeoffs — PlangOS v1 image

| Chose | Over | Because |
|---|---|---|
| Debian 13 (trixie) | Alpine (v1 server image) | Chromium needs glibc. Alpine stays as the headless server image. |
| Assemble with `dpkg-deb -x`, no maintainer scripts | `apt install` in a container | Install scripts can't run unprivileged (dbus sets a setuid helper, systemd creates users). Skipping them also keeps systemd, dbus, PAM and every shell out, and removes a source of nondeterminism. Cost: we generate 4 caches by hand. |
| Host apt resolving from an empty status | podman/buildah build | No container runtime is needed at all. Rootless podman doesn't work in this box, and it may not work on every build machine either. |
| snapshot.debian.org at a fixed timestamp + sha256 lock | Live mirror + digest-pinned base image | The lock pins every byte of every package; there is no base image to pin. Moving to newer packages is an explicit `build.sh lock` + commit. |
| Deny Mesa (LLVM, gallium, z3: 192 MB) | Ship Mesa's software GL | Chromium renders on the CPU (`--disable-gpu`) with its own SwiftShader; `libgbm` loads drivers on demand. checks.py proves no shipped ELF needs a denied library. |
| xz (224 MB) | gzip (326 MB) | Only xz fits under 300 MB. Host plang downloads and verifies the file, so it can decompress before `wsl --import`. Fixed block size keeps the output identical on any machine. |
| No `[boot] command` in wsl.conf | v1's `command = /opt/plang/plang` | A boot command runs as root at distro start, and would be a second plang next to the one host plang starts. |
| passwd shell = `/opt/plang/plang` for both users | `/usr/sbin/nologin` for root | WSL starts the user's shell; there is no shell to fall back to. `wsl -u root` from Windows is the Windows user's own power, not the container's. |
| `/home/plang` = everything user-owned | A separate `/data` | `wsl --import` replaces the whole disk, so no directory survives a re-import by itself. Keeping the data under one tree makes host-side carry-over (export/import of `/home/plang`) a single path. |
| Keep Playwright's linux-x64 Node (~44 MB compressed) | Drop it | Still open whether plang drives Chromium through Playwright; it fits under 300 MB either way. |
| Keep all Chromium locales, gconv, adwaita icons | Trim further | Under the limit already; trimming them risks breaking dialogs and non-English UI for little gain. |
| Remove Debian's `/usr/bin/chromium` launcher | Keep it | It's a shell script. plang starts `/usr/lib/chromium/chromium` directly. |
