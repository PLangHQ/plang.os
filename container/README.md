# plangOS container

Minimal Alpine-musl container image that runs PLang under tini as a non-root
process on a read-only rootfs. The final image contains no shell, no package
manager, and no setuid binaries.

## Layout

```
container/
├── Containerfile         # multi-stage, digest-pinned, no runtime shell
├── build.sh              # reproducible wrapper (multi-arch, SBOM, scan, sign)
├── .dockerignore         # restricts build context to Containerfile + zips
├── plang-amd64.zip       # <-- YOU PROVIDE: linux-musl-x64   self-contained publish
└── plang-arm64.zip       # <-- YOU PROVIDE: linux-musl-arm64 self-contained publish
```

## Required inputs

**PLang must be published as a self-contained, musl-targeted .NET build.** The
release zips on `github.com/PLangHQ/plang/releases` target glibc (`linux-x64`)
and will segfault on Alpine. For this image you need:

```sh
# inside the PLang repo
dotnet publish PLang/PLang.csproj \
  -c Release \
  -r linux-musl-x64 \
  --self-contained true \
  -p:PublishTrimmed=true \
  -p:InvariantGlobalization=true \
  -o out-musl-x64

cd out-musl-x64 && zip -r ../plang-amd64.zip . && cd ..

# same for arm64:
dotnet publish PLang/PLang.csproj -c Release -r linux-musl-arm64 \
  --self-contained true -p:PublishTrimmed=true -p:InvariantGlobalization=true \
  -o out-musl-arm64
cd out-musl-arm64 && zip -r ../plang-arm64.zip . && cd ..
```

Place the resulting zips at `container/plang-amd64.zip` and
`container/plang-arm64.zip`. The Containerfile extracts them into `/opt/plang`
and expects an executable named `plang` (or `PLang`, which is renamed to
`plang` during staging).

Why musl + trimmed + invariant-globalization:
- **musl** is what Alpine ships; glibc builds won't run
- **trimmed** drops unused framework assemblies (~50–100 MB saved)
- **invariant-globalization** drops ICU (~30 MB) — if any PLang module needs
  locale-aware string comparison, remove this flag and the image grows by ICU

## Building

```sh
# from repo root
./container/build.sh
```

Requires: `docker` (with `buildx`), `git`, `sha256sum`, `jq`.
Optional (for full security posture): `syft`, `trivy`, `cosign`.

Outputs land under `.bot/os-v1-container/os/v1/`:
- `image.oci.tar` — deterministic multi-arch OCI archive
- `sbom.spdx.json` — SBOM (if syft installed)
- `trivy.json` — vuln scan (if trivy installed; build fails on HIGH/CRITICAL)
- `build-record.json` — digests, inputs, and base image pins for this build

Two back-to-back runs with the same git HEAD and the same zip digests produce
the same OCI archive digest. If they don't, find the source of nondeterminism
(usually a timestamp somewhere) and pin it.

## Running

The image is designed to run under strict runtime defaults:

```sh
docker run --rm \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --user 10001:10001 \
  plang-os:<tag> --version
```

There is no shell to `exec` into. Debugging is done by building a separate
debug variant (future work) — the shipped image is deliberately opaque.

## What this image is not (yet)

- Not a bootable appliance (no kernel, no initramfs, no dm-verity). See a
  later version for ISO/UKI.
- Not NativeAOT-compiled. PLang's reflection surface needs auditing first.
- Not using a custom seccomp profile. v1 relies on runtime defaults; v2 adds
  a strace-derived profile.
