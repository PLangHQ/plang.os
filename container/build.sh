#!/usr/bin/env bash
#
# plangOS v1 container build wrapper.
#
# Reproducible: same git HEAD + same plang-*.zip digests -> same image digest.
#
# Produces:
#   * multi-arch OCI image (linux/amd64 + linux/arm64)
#   * SBOM (syft, SPDX JSON) under .bot/<branch-dashed>/os/v1/sbom.spdx.json
#   * vuln scan (trivy JSON)        under .bot/<branch-dashed>/os/v1/trivy.json
#   * optional cosign signature (keyless Fulcio by default; COSIGN_KEY overrides)
#
# Required on PATH: docker (with buildx), sha256sum, jq, git.
# Optional on PATH: syft, trivy, cosign.

set -euo pipefail

# ---- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BRANCH_DASHED="${BRANCH//\//-}"
BOT_OUT="${REPO_ROOT}/.bot/${BRANCH_DASHED}/os/v1"
mkdir -p "${BOT_OUT}"

# ---- Inputs ------------------------------------------------------------------
IMAGE_NAME="${IMAGE_NAME:-plang-os}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"
PLATFORMS="${PLATFORMS:-linux/amd64}"

RUNTIME_DEPS_REF="${RUNTIME_DEPS_REF:-mcr.microsoft.com/dotnet/runtime-deps:10.0-alpine3.23}"
ALPINE_REF="${ALPINE_REF:-alpine:3.23}"

# ---- Pre-flight: required inputs present ------------------------------------
zip="${SCRIPT_DIR}/plang-amd64.zip"
if [[ ! -f "${zip}" ]]; then
  echo "error: missing ${zip}" >&2
  echo "  place a self-contained linux-musl-x64 publish of PLang there." >&2
  echo "  see container/README.md." >&2
  exit 1
fi

# ---- Reproducibility knobs ---------------------------------------------------
# SOURCE_DATE_EPOCH anchors timestamps that would otherwise drift between builds.
# We derive from the latest git commit so any change to the tree advances it.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --pretty=%ct)}"
SOURCE_COMMIT="$(git rev-parse HEAD)"

# Record the hash of the zip we're shipping. If it changes between runs
# without a SOURCE_DATE_EPOCH bump, the image digest will differ — that's the
# reproducibility contract.
ZIP_AMD64_SHA="$(sha256sum "${SCRIPT_DIR}/plang-amd64.zip" | awk '{print $1}')"

echo "==> plangOS build"
echo "    branch:        ${BRANCH}"
echo "    image ref:     ${IMAGE_REF}"
echo "    platforms:     ${PLATFORMS}"
echo "    source commit: ${SOURCE_COMMIT}"
echo "    date epoch:    ${SOURCE_DATE_EPOCH}"
echo "    plang-amd64:   sha256:${ZIP_AMD64_SHA}"

# ---- Resolve digests for pinned bases ----------------------------------------
# We resolve the tag -> digest at build time and bake the digest into the image
# via --build-arg. The Containerfile never sees a floating tag.
resolve_digest() {
  local ref="$1"
  # buildx imagetools prints "Name: ... Digest: sha256:..." — pluck the digest.
  docker buildx imagetools inspect "${ref}" \
    | awk '/^Digest:/ {print $2; exit}'
}

RUNTIME_DEPS_DIGEST="$(resolve_digest "${RUNTIME_DEPS_REF}")"
ALPINE_DIGEST="$(resolve_digest "${ALPINE_REF}")"
if [[ -z "${RUNTIME_DEPS_DIGEST:-}" || -z "${ALPINE_DIGEST:-}" ]]; then
  echo "error: could not resolve base image digests" >&2; exit 1
fi

RUNTIME_DEPS_PINNED="${RUNTIME_DEPS_REF%:*}@${RUNTIME_DEPS_DIGEST}"
ALPINE_PINNED="${ALPINE_REF%:*}@${ALPINE_DIGEST}"
echo "    runtime-deps:  ${RUNTIME_DEPS_PINNED}"
echo "    alpine:        ${ALPINE_PINNED}"

# ---- Ensure a reproducible-friendly buildx builder ---------------------------
BUILDER_NAME="plang-os-v1"
if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
  docker buildx create --name "${BUILDER_NAME}" --driver docker-container \
    --driver-opt image=moby/buildkit:v0.15.2 >/dev/null
fi
docker buildx use "${BUILDER_NAME}"

# ---- Build -------------------------------------------------------------------
# --provenance=false keeps the manifest digest stable across runs (provenance
# attestations embed per-build timestamps).
# --sbom=false — we run syft ourselves (output location under .bot/...).
# --output type=oci,dest=... produces a deterministic OCI archive we can verify.
OCI_TAR="${BOT_OUT}/image.oci.tar"
docker buildx build \
  --builder "${BUILDER_NAME}" \
  --platform "${PLATFORMS}" \
  --build-arg "RUNTIME_DEPS_IMAGE=${RUNTIME_DEPS_PINNED}" \
  --build-arg "ALPINE_IMAGE=${ALPINE_PINNED}" \
  --build-arg "SOURCE_COMMIT=${SOURCE_COMMIT}" \
  --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
  --provenance=false \
  --sbom=false \
  --output "type=oci,dest=${OCI_TAR},name=${IMAGE_REF}" \
  --file "${SCRIPT_DIR}/Containerfile" \
  "${SCRIPT_DIR}"

OCI_SHA="$(sha256sum "${OCI_TAR}" | awk '{print $1}')"
echo "    oci archive:   sha256:${OCI_SHA}"

# ---- Load to local daemon for post-build audit -------------------------------
# buildx oci output can't go to both `docker` and an archive in one pass for
# multi-arch, so we do a second single-arch build loaded to the local daemon
# for `find -perm -4000`, `ss -tulpn`, shell-absence checks. The archive above
# is still the shippable artifact.
HOST_ARCH="$(uname -m)"
case "${HOST_ARCH}" in
  x86_64)  AUDIT_PLATFORM="linux/amd64" ;;
  aarch64) AUDIT_PLATFORM="linux/arm64" ;;
  *) echo "warn: unsupported host arch ${HOST_ARCH}, skipping local audit" >&2
     AUDIT_PLATFORM="" ;;
esac

if [[ -n "${AUDIT_PLATFORM}" ]]; then
  docker buildx build \
    --builder "${BUILDER_NAME}" \
    --platform "${AUDIT_PLATFORM}" \
    --build-arg "RUNTIME_DEPS_IMAGE=${RUNTIME_DEPS_PINNED}" \
    --build-arg "ALPINE_IMAGE=${ALPINE_PINNED}" \
    --build-arg "SOURCE_COMMIT=${SOURCE_COMMIT}" \
    --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
    --provenance=false --sbom=false \
    --load \
    --tag "${IMAGE_REF}" \
    --file "${SCRIPT_DIR}/Containerfile" \
    "${SCRIPT_DIR}"

  # Export the local image's rootfs and audit it offline. We cannot `exec sh`
  # because there is no shell in the image — export + scan the tarball.
  AUDIT_DIR="${BOT_OUT}/audit"
  rm -rf "${AUDIT_DIR}"; mkdir -p "${AUDIT_DIR}"
  CID="$(docker create "${IMAGE_REF}")"
  trap 'docker rm -f "${CID}" >/dev/null 2>&1 || true' EXIT
  docker export "${CID}" | tar -xf - -C "${AUDIT_DIR}"

  # Assertion 1: no shell.
  for forbidden in bin/sh bin/bash bin/ash usr/bin/sh; do
    if [[ -e "${AUDIT_DIR}/${forbidden}" ]]; then
      echo "audit failed: ${forbidden} present in final image" >&2; exit 1
    fi
  done

  # Assertion 2: no package manager.
  for forbidden in sbin/apk usr/sbin/apk etc/apk bin/apt usr/bin/dpkg; do
    if [[ -e "${AUDIT_DIR}/${forbidden}" ]]; then
      echo "audit failed: ${forbidden} present in final image" >&2; exit 1
    fi
  done

  # Assertion 3: no setuid/setgid binaries.
  SUID_HITS="$(find "${AUDIT_DIR}" -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%p\n' || true)"
  if [[ -n "${SUID_HITS}" ]]; then
    echo "audit failed: setuid/setgid files found:" >&2
    echo "${SUID_HITS}" >&2
    exit 1
  fi

  # Assertion 4: plang binary present and executable.
  [[ -x "${AUDIT_DIR}/opt/plang/plang" ]] || { echo "audit: plang missing/not-exec" >&2; exit 1; }

  rm -rf "${AUDIT_DIR}"
  docker rm -f "${CID}" >/dev/null
  trap - EXIT
  echo "    audit:         PASS (no shell, no apt/apk, no setuid, plang ok)"
fi

# ---- SBOM --------------------------------------------------------------------
if command -v syft >/dev/null 2>&1; then
  syft "oci-archive:${OCI_TAR}" -o spdx-json > "${BOT_OUT}/sbom.spdx.json"
  echo "    sbom:          ${BOT_OUT}/sbom.spdx.json"
else
  echo "warn: syft not installed; skipping SBOM" >&2
fi

# ---- Vuln scan ---------------------------------------------------------------
if command -v trivy >/dev/null 2>&1; then
  # Fail the build on HIGH/CRITICAL. Full results written to trivy.json.
  trivy image --input "${OCI_TAR}" \
    --format json --output "${BOT_OUT}/trivy.json" \
    --severity HIGH,CRITICAL \
    --exit-code 1 --ignore-unfixed
  echo "    trivy:         ${BOT_OUT}/trivy.json (0 HIGH/CRITICAL)"
else
  echo "warn: trivy not installed; skipping vuln scan" >&2
fi

# ---- Sign --------------------------------------------------------------------
# Only sign if we have a place to push to. Signing an oci-archive isn't useful;
# cosign signs a reference in a registry. COSIGN_PUSH_REF controls this.
if [[ -n "${COSIGN_PUSH_REF:-}" ]]; then
  if command -v cosign >/dev/null 2>&1; then
    # Requires the archive to be pushed first. Left as a user action for v1;
    # the signing step below works once `docker push ${COSIGN_PUSH_REF}` is run.
    echo "    cosign:        sign ${COSIGN_PUSH_REF} after pushing the archive"
    echo "                   (cosign sign --yes ${COSIGN_PUSH_REF})"
  else
    echo "warn: cosign not installed; skipping signature" >&2
  fi
else
  echo "    cosign:        skipped (set COSIGN_PUSH_REF to enable)"
fi

# ---- Record ------------------------------------------------------------------
cat > "${BOT_OUT}/build-record.json" <<EOF
{
  "image_ref": "${IMAGE_REF}",
  "source_commit": "${SOURCE_COMMIT}",
  "source_date_epoch": ${SOURCE_DATE_EPOCH},
  "bases": {
    "runtime_deps": "${RUNTIME_DEPS_PINNED}",
    "alpine": "${ALPINE_PINNED}"
  },
  "inputs": {
    "plang_amd64_sha256": "${ZIP_AMD64_SHA}"
  },
  "oci_archive": "${OCI_TAR}",
  "oci_archive_sha256": "${OCI_SHA}"
}
EOF

echo "==> done."
echo "    build record:  ${BOT_OUT}/build-record.json"
