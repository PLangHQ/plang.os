# plangOS v1 — Attack Surface Checklist

Filled per the checklist in `CLAUDE.md`. One row per item.

| Item | Status | Notes |
|---|---|---|
| Base image | `mcr.microsoft.com/dotnet/runtime-deps:10.0-alpine3.23` + `alpine:3.23` (staging only, discarded) | **Digest-pinned** at build time by `build.sh`. Tag alone is never used. |
| Packages installed | `unzip`, `ca-certificates` | In staging stage only. Discarded — not in final image. |
| Binaries in `$PATH` | 2 — `tini`, `plang` | `$PATH=/opt/plang:/usr/local/bin`. Contains only our two executables. |
| Shell | **absent** | `/bin/sh`, `/bin/ash`, `/bin/bash`, `/bin/busybox` all removed. build.sh audit fails if any are present. |
| Package manager | **absent** | apk + `/etc/apk` + `/var/cache/apk` removed. |
| Setuid binaries | **none** | `find / -perm -4000 -o -perm -2000` via build.sh rootfs scan; fails build if any exist. |
| Open ports | **0** | Image defines no `EXPOSE`. PLang as a CLI doesn't listen. Caller adds `-p` at runtime if a goal serves HTTP. |
| Capabilities | **none required** | Recommended runtime: `--cap-drop=ALL`. Future needs (e.g. `CAP_NET_BIND_SERVICE`) added explicitly. |
| Filesystem | read-only root at runtime (`--read-only`); `/tmp` tmpfs; data dir mounted by caller | Image's `WORKDIR=/home/plang` is writable only when the caller mounts something there. |
| User | UID 10001, GID 10001, non-root, `/sbin/nologin` | `USER 10001:10001` in Containerfile. `/etc/passwd` baked with exactly 2 entries. |
| Secrets | **none baked in** | API keys, settings, data all mounted at runtime. `.dockerignore` restricts build context to the two zips + Containerfile. |
| CVEs | Scanned by trivy in build.sh; HIGH/CRITICAL fails the build | Requires `trivy` on PATH. Report: `.bot/os-v1-container/os/v1/trivy.json`. |
| Image signature | cosign-ready; signs when `COSIGN_PUSH_REF` is set | Default is keyless via Fulcio. `COSIGN_KEY` env var for explicit key. |
| SBOM | SPDX JSON via syft | Output: `.bot/os-v1-container/os/v1/sbom.spdx.json`. Requires `syft` on PATH. |

## What's still reachable (and why)

Even with the image locked down, these are the things an attacker inside the
container could still do:

| Vector | Mitigation |
|---|---|
| Calls to external APIs (LLM providers, HTTP endpoints PLang goals target) | Runtime caller controls egress; no mitigation in image. A future appliance variant can add nftables default-deny + explicit allow-list. |
| Filesystem access within mounted volumes | Caller decides mount mode. Recommend `:ro` wherever PLang only reads. |
| Memory exhaustion | `--memory` flag by caller. Image doesn't enforce. |
| Fork bombs | `--pids-limit=64` by caller. |
| .NET reflection / dynamic code loading | Inherent to PLang. Image can't mitigate. AOT would, but v1 uses JIT (tradeoffs.md). |
| Side-channel attacks (Spectre/Meltdown family) | Kernel concern; out of image scope. |

## Future hardening (v2+)

- Custom seccomp profile derived from `strace -c -f plang --test …`
- AppArmor profile (Debian/Ubuntu hosts)
- SELinux policy module (RHEL/Fedora hosts)
- Optional NativeAOT variant (removes JIT + reflection attack surface, pending
  audit of PLang's reflection use)
- Appliance variant with dm-verity + Secure Boot + UKI + nftables default-deny
