# plangOS v1 — Session Summary

## What this is

The bootstrap iteration of plangOS. Before v1 the repo had only `CLAUDE.md`,
`README.md`, and `characters/`. v1 delivers the first concrete artifact: a
digest-pinned, reproducible, multi-arch (amd64 + arm64) Alpine-musl container
image that runs PLang on .NET 10 as a single, locked-down process under tini.
No shell, no package manager, no setuid binaries in the final image.

Appliance (ISO/UKI/dm-verity), custom seccomp, AppArmor/SELinux profiles, and
NativeAOT are explicitly deferred. v1 is the container-first baseline.

## What was done

### Added

- `container/Containerfile` — two-stage build. Staging uses `alpine:3.23` to
  download tini (SHA-256 verified), copy `plang-${TARGETARCH}.zip` from the
  build context, unzip, bake minimal `/etc/passwd` + `/etc/group` for UID
  10001. Runtime uses `runtime-deps:10.0-alpine3.23`, copies the prepared
  rootfs, then a single `RUN` strips busybox, apk, and all shells — including
  `/bin/busybox` itself.
- `container/build.sh` — reproducible wrapper. Derives `SOURCE_DATE_EPOCH`
  from the last git commit, resolves base image tags to digests at build time
  via `docker buildx imagetools inspect`, builds the multi-arch OCI archive
  with `--provenance=false --sbom=false` (for digest stability), then does a
  single-arch `--load` build + rootfs export to audit the final image for
  absent shell / absent apk / no setuid. Runs syft + trivy if installed.
  Records all inputs and outputs in `build-record.json`.
- `container/.dockerignore` — restricts context to `Containerfile` + the two
  PLang zips.
- `container/README.md` — documents the musl publish requirement
  (`dotnet publish -r linux-musl-x64 --self-contained`), build command, and
  recommended runtime flags.

### Bot output (`.bot/os-v1-container/os/v1/`)

- `plan.md` — approved plan
- `lockdown.md` — image vs runtime lockdown table, seccomp/AppArmor/SELinux
  status, signal semantics
- `attack-surface.md` — filled checklist per CLAUDE.md
- `tradeoffs.md` — every decision with "chose X over Y because"
- `measurements.md` — targets + the exact commands to fill in measured values
  on the first local build
- `summary.md` — this file

### Reports

- `.bot/os-v1-container/report.json` — session entry with `before`, `plan`,
  batched `actions`, and `after` blocks
- `.bot/os-v1-container/os-report.json` — OS-bot-specific report per CLAUDE.md
  schema

## Key decisions (see tradeoffs.md for full reasoning)

- Alpine musl over Debian slim (size)
- Self-contained trimmed + invariant-globalization over NativeAOT (reflection
  audit deferred)
- tini over PLang-as-PID-1 (PLang lacks SIGCHLD code)
- No runtime shell — tini execs `/opt/plang/plang` directly. Integrity checks
  moved to build-time rootfs audit in `build.sh`
- In-repo zip inputs (per user direction) instead of network download
- Base digests resolved at build time, recorded in `build-record.json`

## Code example — the "no shell" enforcement

The pattern in the Containerfile that makes this image different from the
usual "small Alpine image":

```dockerfile
# Strip the shell and package manager from the final image. The single RUN
# runs busybox to remove everything including itself. The layer that gets
# written doesn't have busybox or any shell.
RUN /bin/busybox rm -rf \
      /sbin/apk /etc/apk /usr/sbin/apk /var/cache/apk \
      /bin/sh /bin/ash /bin/bash /bin/login /bin/su \
      /usr/bin/wget /usr/bin/ftp /usr/bin/telnet \
      /sbin/reboot /sbin/halt /sbin/poweroff /sbin/init \
      /lib/apk \
 && /bin/busybox rm -f /bin/busybox
```

And `build.sh` verifies the deletion actually stuck by exporting the image's
rootfs and scanning it:

```sh
CID="$(docker create "${IMAGE_REF}")"
docker export "${CID}" | tar -xf - -C "${AUDIT_DIR}"
for forbidden in bin/sh bin/bash bin/ash usr/bin/sh; do
  [[ -e "${AUDIT_DIR}/${forbidden}" ]] && { echo "audit failed"; exit 1; }
done
```

## Status

- **Done**: Containerfile, build.sh, .dockerignore, README.md, bot output
  docs, reports.
- **Not done (requires Docker host)**: actual build, measurement fill-in,
  trivy scan counts. The plan-mode environment has no Docker available; the
  user runs `./container/build.sh` locally to produce the image and fill
  `measurements.md`.
- **Prerequisite for first real build**: user must produce
  `container/plang-amd64.zip` and `container/plang-arm64.zip` as
  `linux-musl-x64` / `linux-musl-arm64` self-contained publishes (command in
  `container/README.md`). The public `plang-linux-x64.zip` release is glibc
  and won't run on Alpine.

## Next version candidates

- **v2**: custom seccomp from strace, AppArmor profile, optional NativeAOT
  variant (needs reflection audit), actual measurements backfilled.
- **v3+**: bootable appliance — mkosi config, kernel config, initramfs, UKI,
  dm-verity, Secure Boot integration.
