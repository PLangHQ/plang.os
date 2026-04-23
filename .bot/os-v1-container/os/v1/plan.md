# plangOS v1 — First Container Image

## Context

Bootstrap iteration of plangOS. Before v1, the repo was only `CLAUDE.md`,
`README.md`, and `characters/` — no image definitions, no build scripts, no
PLang binary. v1 produces the first concrete artifact: a digest-pinned,
reproducible, multi-arch (amd64 + arm64) container image that runs PLang on
.NET 10 as a single, locked-down process on Alpine musl.

We scope v1 to the container artifact only. The bootable appliance
(ISO / UKI / dm-verity) is a much larger build surface and will land in a
later version once v1's lockdown and measurement story is settled.

## Decisions (confirmed with user)

| Area | Decision |
|---|---|
| PLang source | `plang-amd64.zip` + `plang-arm64.zip` committed to `container/` — no network download at build time |
| Base image | Alpine musl — `mcr.microsoft.com/dotnet/runtime-deps:10.0-alpine3.23`, digest-pinned by build.sh |
| Architectures | Multi-arch manifest: `linux/amd64` + `linux/arm64` (buildx) |
| Entrypoint model | No runtime shell. `tini` execs `/opt/plang/plang` directly. Integrity gates happen at **build** time, not runtime |
| Branch | `os/v1-container` off `main` |

## Approach

### Multi-stage build

1. **Staging stage** (`alpine:3.23`, digest-pinned, discarded): downloads tini,
   verifies its SHA-256, copies `plang-${TARGETARCH}.zip` from the build
   context, unzips, normalizes the binary name, bakes minimal `/etc/passwd`
   and `/etc/group` entries for UID 10001.
2. **Runtime stage** (`runtime-deps:10.0-alpine3.23`, digest-pinned):
   `COPY --from=staging` of just the prepared rootfs pieces, then a single
   `RUN` that removes busybox, apk, login utilities, and finally deletes
   `/bin/busybox` itself. No shell remains in the final image.

### .NET packaging (the user produces the zips)

Documented in `container/README.md`:
- `dotnet publish -c Release -r linux-musl-x64 --self-contained true
   -p:PublishTrimmed=true -p:InvariantGlobalization=true`
- Same with `linux-musl-arm64` for the arm64 zip.

No NativeAOT in v1. PLang uses heavy reflection (LLM-mapped modules, source
generators, dynamic handler dispatch). AOT trimming warnings need a dedicated
audit — revisit in a later version.

### PID 1

tini as PID 1, PLang as its only child. ~10 KB, proven zombie reaper, forwards
signals cleanly. PLang-as-PID-1 would require PLang to implement SIGCHLD
reaping + signal forwarding — that's a PLang runtime change, not an OS change.

### Lockdown

Image-level:
- `USER 10001:10001`, non-root
- No shell, no package manager, no login utilities (verified by build.sh after
  image assembly — see "audit" section below)
- No setuid/setgid binaries (verified by build.sh via rootfs scan)

Runtime-level (documented in `container/README.md`, enforced by the caller):
- `--read-only`, `/tmp` as tmpfs
- `--cap-drop=ALL`
- `--security-opt=no-new-privileges`
- Default Docker seccomp profile in v1 (custom profile is v2 work)

### Integrity & reproducibility

- Base images (`runtime-deps:10.0-alpine3.23` and `alpine:3.23`) pinned by
  SHA-256 digest at build time: `build.sh` resolves the digest via
  `docker buildx imagetools inspect` and passes it as `--build-arg`
- `SOURCE_DATE_EPOCH` derived from the last git commit timestamp
- `--provenance=false --sbom=false` on `docker buildx build` to avoid
  per-build timestamp attestations that change the digest
- PLang zip SHA-256s recorded in `.bot/os-v1-container/os/v1/build-record.json`
- syft SBOM generation (optional, skipped with warning if not installed)
- trivy HIGH/CRITICAL scan (optional, fails build on findings)
- cosign signing hook (documented, triggered via `COSIGN_PUSH_REF` env var)

### Build-time audit (replaces runtime integrity checks)

Because there's no shell in the final image, `docker exec` can't audit it. The
build script does the audit offline:

1. Builds a single-arch variant and `--load`s it to the local daemon
2. `docker create` + `docker export | tar -xf -` to get the rootfs
3. Asserts: no `/bin/sh`, no `apk`, no setuid/setgid files, plang+tini present
4. Fails the build if any assertion fails

## Files produced

Repo (canonical build inputs):
- `container/Containerfile`
- `container/build.sh`
- `container/.dockerignore`
- `container/README.md` — explains the zip requirement + musl publish command

Bot output (`.bot/os-v1-container/os/v1/`):
- `plan.md` (this file)
- `lockdown.md`
- `attack-surface.md`
- `tradeoffs.md`
- `measurements.md` (skeleton — user fills after first local build)
- `summary.md`

Reports:
- `.bot/os-v1-container/report.json`
- `.bot/os-v1-container/os-report.json`

## Verification

1. `./container/build.sh` produces a multi-arch OCI archive + build-record.json
2. Second run with same HEAD + same zips → identical OCI archive SHA-256
3. `docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges
   --user 10001:10001 plang-os:<tag> --version` runs PLang, exits 0
4. `docker run --rm --entrypoint /bin/sh plang-os:<tag>` fails (no shell)
5. `docker exec <running-container> sh` fails (no shell to exec)
6. build.sh's audit pass asserts the above before the image ships

## Out of scope for v1 (explicit non-goals)

- Bootable appliance (ISO / UKI / dm-verity / Secure Boot)
- Custom seccomp profile
- NativeAOT publish
- nftables / host firewall
- TPM attestation / measured boot
- Debug variant of the image (future work when someone actually needs to
  inspect a running container)
