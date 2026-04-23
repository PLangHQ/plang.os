# plang.os

Minimal-Linux image-building infrastructure for PLang. This repo produces:

- **Container images** (OCI) — smallest viable Linux + .NET 10 runtime + PLang, running as PID 1 (directly or under tini).
- **Bootable appliances** — ISO / VM disk / raw image that boots straight into PLang. No shell, no SSH, no login.
- **Reproducible build scripts** — same inputs → same image digest.

## Core Constraints

1. **Smallest possible Linux.** Every binary, every file, every open port must justify itself.
2. **Only PLang runs.** No shell in the final image, read-only root, seccomp-filtered exec, `CAP_DROP=ALL` by default.
3. **Hash-pinned integrity.** Container: base images by digest + cosign signatures. Appliance: dm-verity + Secure Boot + UKI.
4. **Reproducible.** `SOURCE_DATE_EPOCH`, pinned toolchain versions, deterministic tar/cpio ordering.
5. **Security-first networking.** nftables default-deny, no SSH, no debug daemons, explicit listen-port accounting.

## Distro Choices (tradeoffs to weigh)

- **Alpine** (musl, ~5 MB) — smallest, but .NET needs the `linux-musl-x64` runtime and some P/Invoke libs break on musl.
- **Debian slim / Ubuntu minimal** (glibc, ~30 MB) — broader .NET compatibility.
- **Distroless** — no package manager, no shell, binaries only.
- **From-scratch / Buildroot / mkosi** — every file deliberate.
- **Chisel** — slice Ubuntu packages into minimal file sets.

## .NET 10 on Linux

- **Runtime-only** vs **self-contained** vs **NativeAOT** — each has size/startup/compat tradeoffs.
- **Trimming** (`PublishTrimmed=true`) — watch for reflection warnings.
- **NativeAOT** — single static binary, no JIT, ~20 MB. Breaks on heavy reflection.
- **ReadyToRun** — faster startup, larger size.
- **Globalization invariant mode** — drops ICU (~30 MB) if you don't need locales.

## Directory Layout

```
plang.os/
├── CLAUDE.md                       # this file
├── README.md                       # public-facing project description
├── container/                      # container image definitions
│   ├── Containerfile               # OCI image definition (Alpine-based by default)
│   └── build.sh                    # reproducible build wrapper
├── appliance/                      # bootable appliance build
│   ├── mkosi.conf                  # mkosi config
│   ├── kernel.config               # kernel build config
│   └── initramfs/                  # initramfs scripts
├── scripts/                        # shared build/verify scripts
└── .bot/                           # bot output, one dir per branch (never merged to main)
```

## Branch Flow

- Default branch: `main`
- Feature branches: `os/<topic>` (written by the `os` bot)
- `.bot/<branch>/` accumulates bot output on feature branches; the `main` branch stays clean
- Release flow: to be defined

## What the OS Bot Produces Per Task

Each invocation writes to `.bot/<branch>/os/v<N>/`:

- **`Containerfile`** or **`appliance/`** — the artifact(s) for this iteration
- **`build.sh`** — reproducible build wrapper
- **`lockdown.md`** — process lockdown (capabilities, seccomp, AppArmor, read-only mounts)
- **`measurements.md`** — image size, layer breakdown, startup time, RSS at idle
- **`attack-surface.md`** — filled attack-surface checklist
- **`tradeoffs.md`** — every decision: "Chose X over Y because …"

## Attack Surface Checklist (fill per image)

- [ ] Base image — distro, version, **digest-pinned**
- [ ] Packages installed — each one justified
- [ ] Binaries in `$PATH` — count minimised
- [ ] Shell — ideally absent
- [ ] Package manager — absent in final image
- [ ] Setuid binaries — `find / -perm -4000` → delete or justify
- [ ] Open ports — `ss -tulpn`, each documented
- [ ] Capabilities — minimum set, listed
- [ ] Filesystem — read-only root, writable paths enumerated
- [ ] User — non-root UID, documented
- [ ] Secrets — none baked in, mounted at runtime
- [ ] CVEs — `trivy` / `grype` scan, findings reported
- [ ] Image signature — cosign signed
- [ ] SBOM — generated (`syft`), published

## Philosophy

Small images aren't the goal — **deliberate images are**. Every byte in the image is a byte an attacker can work with. If you can't explain why a file is present, delete it.

"Works on my machine" is a security vulnerability. Reproducibility is what makes signatures meaningful.
