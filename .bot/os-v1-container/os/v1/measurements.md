# plangOS v1 — Measurements

**Status: expected values + measurement plan.** I don't have Docker available
in the plan-mode environment that produced v1, so the numbers below are either
(a) computed from the Containerfile's inputs or (b) targets to verify on the
first real local build.

Run `./container/build.sh` locally, then fill the `Measured` columns from the
commands in **How to measure** below.

## Image size (target vs measured)

| Layer source | Target (≤) | Measured amd64 | Measured arm64 |
|---|---|---|---|
| `runtime-deps:10.0-alpine3.23` | ~20 MB | | |
| PLang (self-contained, trimmed, invariant-globalization) | ~70 MB | | |
| tini | 1 MB | | |
| Final image total | **≤ 100 MB** | | |

The target of 100 MB is per-arch. A multi-arch manifest is roughly additive on
the registry side (amd64 + arm64 layers stored separately, shared metadata).

If PLang's trimmed publish can't get below ~70 MB, the dominant cost is the
.NET runtime bundled in self-contained mode. Moving to NativeAOT in a future
version would bring the app layer to ~20–30 MB — but requires the reflection
audit covered in `tradeoffs.md`.

## Startup

| Metric | Target | Measured |
|---|---|---|
| Container start → PLang main() entry | < 500 ms | |
| `plang --version` total wall time | < 1.5 s | |
| Idle RSS (after startup, no goal loaded) | < 80 MB | |

Measurement is sensitive to whether the host has warmed the image layers in
page cache. Run twice and take the second.

## Reproducibility

Target: two consecutive runs of `./container/build.sh` with the same git HEAD
and identical `plang-{amd64,arm64}.zip` produce the same OCI archive digest.

| Run | OCI archive SHA-256 |
|---|---|
| 1 | |
| 2 | |

If digests differ, investigate in this order:
1. `SOURCE_DATE_EPOCH` — did the git commit timestamp change?
2. Zip hashes — did `container/plang-*.zip` change?
3. Base image digests — did `docker buildx imagetools inspect` resolve to a
   newer digest? (build-record.json captures this.)
4. Buildkit version — a new buildkit can subtly change layer construction.
5. `--provenance=false --sbom=false` — confirm these flags are on.

## Vuln surface (trivy)

| Severity | Count | |
|---|---|---|
| CRITICAL | 0 (target) | build fails if nonzero |
| HIGH | 0 (target) | build fails if nonzero |
| MEDIUM | | report only |
| LOW | | report only |

## How to measure

```sh
# Image size
docker image inspect plang-os:<tag> --format='{{.Size}}' | numfmt --to=iec

# Layer breakdown (requires `dive` — optional)
dive plang-os:<tag>

# Startup — cold cache, twice for warm cache
time docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --user 10001:10001 plang-os:<tag> --version

# Idle RSS
CID=$(docker run -d --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --user 10001:10001 plang-os:<tag> --wait-forever-or-similar)
docker stats --no-stream --format '{{.MemUsage}}' "$CID"
docker kill "$CID"

# OCI archive digest (for reproducibility check)
sha256sum .bot/os-v1-container/os/v1/image.oci.tar

# Vuln scan summary
jq '[.Results[]?.Vulnerabilities[]?] | group_by(.Severity) | map({(.[0].Severity): length}) | add' \
  .bot/os-v1-container/os/v1/trivy.json
```
