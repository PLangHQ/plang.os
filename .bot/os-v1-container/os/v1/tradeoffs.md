# plangOS v1 — Tradeoffs

Every non-obvious decision, why we chose it, and what we gave up.

## Base image: Alpine musl vs Debian slim

**Chose Alpine 3.23 (musl) over Debian bookworm-slim (glibc).**

- **Size**: `runtime-deps:10.0-alpine3.23` is ~20 MB; `runtime-deps:10.0-bookworm-slim` is ~120 MB. A ~100 MB differential before any app code.
- **Distro philosophy**: Alpine's package set and userland (busybox) are already minimal; fewer things to remove.
- **Cost**: PLang must be published for `linux-musl-x64` / `linux-musl-arm64`. Existing `plang-linux-x64.zip` from the public release is glibc and won't run. We've documented the `dotnet publish -r linux-musl-x64` command the user must run (`container/README.md`). Some reflection-heavy .NET libraries have historically had edge cases on musl; if PLang hits one, the fallback is `runtime-deps:10.0-bookworm-slim` and we accept the size cost.

## Publish mode: self-contained trimmed vs runtime-only vs NativeAOT

**Chose self-contained + trimmed + invariant-globalization.**

- **Self-contained** bundles the .NET runtime with PLang, so we don't need a separate `dotnet` install in the image. Simpler image, no version-mismatch surprises.
- **Trimmed** (`PublishTrimmed=true`) drops unused framework assemblies. Expected saving 50–100 MB. Watch for trim warnings — reflection-heavy paths may break. PLang's LLM-mapped module system uses reflection; the trimmed publish may need `TrimmerRootAssembly` hints in PLang's csproj.
- **Invariant globalization** drops ICU (~30 MB). If PLang needs locale-aware string comparison, this must be off and ICU shipped — image grows by ~30 MB.

**Not using NativeAOT**. PLang's builder and runtime are reflection-heavy (LLM output maps to modules via reflection, source-generated records, dynamic handler dispatch). Making AOT work requires a dedicated audit pass to add `[DynamicallyAccessedMembers]` attributes or `IlcTrim` descriptors. v1 defers this; a later version produces an AOT variant once the reflection surface is charted.

**Not using ReadyToRun**. R2R speeds up startup but adds size. For a container that starts on demand, the startup cost is paid by the user. Revisit if idle-to-ready latency turns out to matter.

## PID 1: tini vs PLang-as-PID-1 vs s6-overlay

**Chose tini.** ~10 KB static binary, SHA-256-pinned download, proven.

- **PLang-as-PID-1** is attractive (one process, one binary) but requires PLang to explicitly implement SIGCHLD reaping and signal forwarding. That's a PLang runtime change, not an OS image change. Revisit when PLang has a signal-handling story.
- **s6-overlay** is overkill for a single-process image. Its value is supervision of multiple processes, which we deliberately don't want.

## Entrypoint model: shell + hash check vs no shell

**Chose no shell.** tini execs `/opt/plang/plang` directly.

- No `/bin/sh` in the image means a compromised process can't drop to a shell and pivot. No `exec sh -c …` from a PLang code-execution bug. No interactive debug access from `docker exec`.
- The cost: no runtime hash check on the PLang binary, no runtime setuid-scan, no startup logging. We replaced these with **build-time** checks in `build.sh` (audit stage that exports the rootfs and scans it offline). This is strictly safer — the image is audited once at build and signed; runtime checks on a potentially-compromised rootfs are security theater.
- The cost: debugging a running container is hard. Mitigated by (a) the image starting/stopping fast, so reproducing the issue in a debug variant is cheap, and (b) a future debug-variant image with a shell, explicitly tagged, never the default.

## Architectures: amd64 + arm64 via buildx

**Chose multi-arch**. Arm64 is ubiquitous now (Apple Silicon, Graviton, Raspberry Pi 4/5). Multi-arch via buildx with QEMU costs ~3× build time on the non-native arch, but that's a CI concern, not a user-facing cost.

## PLang source: in-repo zip vs download

**Chose in-repo zip** (per user direction).

- No network fetch during `docker build` → build works offline, is more reproducible, and removes a supply-chain link (no download server to compromise).
- Cost: the zip must be placed by the user (or CI) before building. `.dockerignore` restricts the build context to just those zips + the Containerfile.
- The zip sha256 is recorded in `build-record.json` alongside the image digest; two builds with the same zip hash + same HEAD produce the same image.

## Base digest pinning: resolved-at-build vs committed-pin

**Chose resolved-at-build** (via `docker buildx imagetools inspect` in `build.sh`).

- A committed pin (`FROM …@sha256:<baked in Containerfile>`) is more transparent — anyone reading the Containerfile sees what's pinned — but requires a commit to bump.
- Resolving at build gives us the latest-pinned version of the base tag without a commit. The digest is recorded in `build-record.json`, so the pin is captured per-build.
- If supply-chain threat model tightens, switch to committed pins in v2. The build-record.json is the bridge: it shows what WAS pinned for each build.

## Reproducibility: provenance/SBOM-off vs on

**Chose `--provenance=false --sbom=false`** at the buildx layer.

- Buildkit's built-in provenance and SBOM attestations include per-build timestamps and buildkit version info, which change the OCI manifest digest between runs. We need digest stability for reproducibility-verification.
- We run syft ourselves for the SBOM (output: `.bot/os-v1-container/os/v1/sbom.spdx.json`) — same data, separate artifact, doesn't affect the image digest.
- If buildkit's provenance becomes attractive (sigstore/witness integration), revisit in a later version and accept the digest drift.

## Signing: keyless Fulcio vs explicit key

**Default: keyless (Fulcio).** Override via `COSIGN_KEY`.

- Keyless is simpler operationally (no key management) but ties trust to the OIDC identity used during CI — acceptable for OSS publishing.
- For air-gapped or high-assurance deployments, `COSIGN_KEY` path lets the caller supply their own key.

## What's deferred

| Deferred | Reason | When it lands |
|---|---|---|
| Bootable appliance (ISO/UKI/dm-verity) | Much larger build surface; needs kernel config, initramfs, Secure Boot keys | v2 or v3 |
| Custom seccomp profile | Needs strace data from a real PLang workload first | v2 |
| AppArmor profile | Host-distro-specific | v2 |
| SELinux policy | Host-distro-specific | v2 |
| NativeAOT variant | Needs PLang reflection-surface audit | Separate track |
| Debug variant of image | Not needed until someone debugs a failing container | On-demand |
