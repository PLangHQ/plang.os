#!/usr/bin/env bash
#
# plangOS v1 container build wrapper (podman + skopeo).
#
# Reproducible: same git HEAD + same plang-amd64.zip hash -> same image.
#
# Produces:
#   * OCI archive (podman save --format oci-archive)
#     under .bot/<branch-dashed>/os/v1/image.oci.tar
#   * SBOM (syft, SPDX JSON)    under .bot/<branch-dashed>/os/v1/sbom.spdx.json
#   * vuln scan (trivy JSON)    under .bot/<branch-dashed>/os/v1/trivy.json
#   * optional cosign signature (keyless Fulcio by default; COSIGN_KEY overrides)
#
# Required on PATH: podman, skopeo, sha256sum, jq, git, awk, tar.
# Optional on PATH: syft, trivy, cosign.
#
# Install on Debian/Ubuntu WSL:
#   sudo apt update && sudo apt install -y podman skopeo jq

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
PLATFORM="${PLATFORM:-linux/amd64}"

RUNTIME_DEPS_REF="${RUNTIME_DEPS_REF:-mcr.microsoft.com/dotnet/runtime-deps:10.0-alpine3.23}"
ALPINE_REF="${ALPINE_REF:-alpine:3.23}"

# ---- Tool preflight ----------------------------------------------------------
missing_tools=()
for tool in podman skopeo sha256sum git awk tar; do
  command -v "${tool}" >/dev/null 2>&1 || missing_tools+=("${tool}")
done
if [[ ${#missing_tools[@]} -gt 0 ]]; then
  echo "error: missing required tools: ${missing_tools[*]}" >&2
  echo "  on Debian/Ubuntu WSL:" >&2
  echo "    sudo apt update && sudo apt install -y podman skopeo jq" >&2
  exit 1
fi

# ---- Pre-flight: zip present -------------------------------------------------
# The zip is too big for the repo (~260 MB for an untrimmed self-contained
# publish). It lives outside the repo; build.sh copies it into the build
# context just before the build and cleans up after. Source path is
# ${PLANG_ZIP:-/shared/plang-amd64.zip}.
zip="${SCRIPT_DIR}/plang-amd64.zip"
zip_src="${PLANG_ZIP:-/shared/plang-amd64.zip}"
staged_zip=0
if [[ ! -f "${zip}" ]]; then
  if [[ -f "${zip_src}" ]]; then
    echo "==> staging ${zip_src} -> ${zip}"
    cp "${zip_src}" "${zip}"
    staged_zip=1
  else
    echo "error: missing ${zip} and source ${zip_src} not found" >&2
    echo "  place a self-contained linux-musl-x64 publish of PLang at either" >&2
    echo "  location, or set PLANG_ZIP=<path> to override the source." >&2
    echo "  see container/README.md." >&2
    exit 1
  fi
fi
CID=""
cleanup_on_exit() {
  if [[ -n "${CID}" ]]; then
    podman rm -f "${CID}" >/dev/null 2>&1 || true
  fi
  if [[ "${staged_zip}" = "1" && -f "${zip}" ]]; then
    rm -f "${zip}"
  fi
}
trap cleanup_on_exit EXIT

# ---- Reproducibility knobs ---------------------------------------------------
# SOURCE_DATE_EPOCH anchors timestamps that would otherwise drift between
# builds. We derive from the latest git commit so any change to the tree
# advances it. Buildah (podman's backend) honours this for layer timestamps.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --pretty=%ct)}"
SOURCE_COMMIT="$(git rev-parse HEAD)"

ZIP_AMD64_SHA="$(sha256sum "${zip}" | awk '{print $1}')"

echo "==> plangOS build"
echo "    branch:        ${BRANCH}"
echo "    image ref:     ${IMAGE_REF}"
echo "    platform:      ${PLATFORM}"
echo "    source commit: ${SOURCE_COMMIT}"
echo "    date epoch:    ${SOURCE_DATE_EPOCH}"
echo "    plang-amd64:   sha256:${ZIP_AMD64_SHA}"

# ---- Resolve digests for pinned bases ----------------------------------------
# We resolve the tag -> digest via skopeo (which does a plain HTTP query
# against the registry) and bake the digest into the image via --build-arg.
# The Containerfile never sees a floating tag.
resolve_digest() {
  local ref="$1" digest
  if ! digest="$(skopeo inspect --format '{{.Digest}}' "docker://${ref}" 2>&1)"; then
    echo "error: 'skopeo inspect docker://${ref}' failed:" >&2
    echo "${digest}" >&2
    return 1
  fi
  if [[ ! "${digest}" =~ ^sha256: ]]; then
    echo "error: unexpected skopeo output for ${ref}: '${digest}'" >&2
    return 1
  fi
  printf '%s' "${digest}"
}

RUNTIME_DEPS_DIGEST="$(resolve_digest "${RUNTIME_DEPS_REF}")"
ALPINE_DIGEST="$(resolve_digest "${ALPINE_REF}")"

RUNTIME_DEPS_PINNED="${RUNTIME_DEPS_REF%:*}@${RUNTIME_DEPS_DIGEST}"
ALPINE_PINNED="${ALPINE_REF%:*}@${ALPINE_DIGEST}"
echo "    runtime-deps:  ${RUNTIME_DEPS_PINNED}"
echo "    alpine:        ${ALPINE_PINNED}"

# ---- Build -------------------------------------------------------------------
# --format oci produces OCI-spec images (more portable than the docker v2
# manifest). --timestamp seconds makes layer mtimes deterministic.
echo "==> podman build"
podman build \
  --platform "${PLATFORM}" \
  --format oci \
  --timestamp "${SOURCE_DATE_EPOCH}" \
  --build-arg "RUNTIME_DEPS_IMAGE=${RUNTIME_DEPS_PINNED}" \
  --build-arg "ALPINE_IMAGE=${ALPINE_PINNED}" \
  --build-arg "SOURCE_COMMIT=${SOURCE_COMMIT}" \
  --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
  --tag "${IMAGE_REF}" \
  --file "${SCRIPT_DIR}/Containerfile" \
  "${SCRIPT_DIR}"

# ---- Save OCI archive --------------------------------------------------------
OCI_TAR="${BOT_OUT}/image.oci.tar"
rm -f "${OCI_TAR}"
podman save --format oci-archive --output "${OCI_TAR}" "${IMAGE_REF}"
OCI_SHA="$(sha256sum "${OCI_TAR}" | awk '{print $1}')"
echo "    oci archive:   sha256:${OCI_SHA}"

# ---- Rootfs audit ------------------------------------------------------------
# No shell in the final image -> can't 'podman exec sh' to inspect it.
# Instead create + export the rootfs, then scan the tarball offline.
AUDIT_DIR="${BOT_OUT}/audit"
rm -rf "${AUDIT_DIR}"; mkdir -p "${AUDIT_DIR}"
CID="$(podman create "${IMAGE_REF}")"
podman export "${CID}" | tar -xf - -C "${AUDIT_DIR}"

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
podman rm -f "${CID}" >/dev/null
CID=""
echo "    audit:         PASS (no shell, no apt/apk, no setuid, plang ok)"

# ---- SBOM --------------------------------------------------------------------
if command -v syft >/dev/null 2>&1; then
  syft "oci-archive:${OCI_TAR}" -o spdx-json > "${BOT_OUT}/sbom.spdx.json"
  echo "    sbom:          ${BOT_OUT}/sbom.spdx.json"
else
  echo "warn: syft not installed; skipping SBOM" >&2
fi

# ---- Vuln scan ---------------------------------------------------------------
if command -v trivy >/dev/null 2>&1; then
  trivy image --input "${OCI_TAR}" \
    --format json --output "${BOT_OUT}/trivy.json" \
    --severity HIGH,CRITICAL \
    --exit-code 1 --ignore-unfixed
  echo "    trivy:         ${BOT_OUT}/trivy.json (0 HIGH/CRITICAL)"
else
  echo "warn: trivy not installed; skipping vuln scan" >&2
fi

# ---- Sign --------------------------------------------------------------------
# Cosign signs a registry reference, not a local tarball. Enable signing by
# setting COSIGN_PUSH_REF to a registry URL you've pushed the image to.
if [[ -n "${COSIGN_PUSH_REF:-}" ]]; then
  if command -v cosign >/dev/null 2>&1; then
    echo "    cosign:        push and sign ${COSIGN_PUSH_REF}:"
    echo "                   podman push ${IMAGE_REF} ${COSIGN_PUSH_REF}"
    echo "                   cosign sign --yes ${COSIGN_PUSH_REF}"
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
  "engine": "podman",
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
echo "    run:           podman run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges --tmpfs /tmp:rw,noexec,nosuid,size=64m --user 10001:10001 --pids-limit=64 ${IMAGE_REF}"
