#!/usr/bin/env bash
#
# plangOS desktop build wrapper (podman).
#
# Produces:
#   * OCI image (in local podman store) — for Linux desktops / non-Windows hosts
#   * WSL distro tarball at .bot/<branch>/os/v2/plangos-desktop-wsl.tar
#     for Windows users to register with `wsl --import`.
#
# Tools: podman, skopeo, unzip, sha256sum, jq, git.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BRANCH_DASHED="${BRANCH//\//-}"
BOT_OUT="${REPO_ROOT}/.bot/${BRANCH_DASHED}/os/v2"
mkdir -p "${BOT_OUT}"

IMAGE_NAME="${IMAGE_NAME:-plang-os-desktop}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"
PLATFORM="${PLATFORM:-linux/amd64}"

RUNTIME_DEPS_REF="${RUNTIME_DEPS_REF:-mcr.microsoft.com/dotnet/runtime-deps:10.0-bookworm-slim}"
DEBIAN_REF="${DEBIAN_REF:-debian:12-slim}"

# ---- Tool preflight ----------------------------------------------------------
missing=()
for t in podman skopeo sha256sum git awk tar; do
  command -v "${t}" >/dev/null 2>&1 || missing+=("${t}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "error: missing required tools: ${missing[*]}" >&2
  echo "  on Debian/Ubuntu WSL: sudo apt install -y podman skopeo jq" >&2
  exit 1
fi

# ---- Zip preflight -----------------------------------------------------------
zip="${SCRIPT_DIR}/plang-desktop-amd64.zip"
zip_src="${PLANG_DESKTOP_ZIP:-/shared/plang-desktop-amd64.zip}"
staged_zip=0
if [[ ! -f "${zip}" ]]; then
  if [[ -f "${zip_src}" ]]; then
    echo "==> staging ${zip_src} -> ${zip}"
    cp "${zip_src}" "${zip}"
    staged_zip=1
  else
    echo "error: missing ${zip} and source ${zip_src} not found" >&2
    echo "  publish the Photino-based plang variant (linux-x64, self-contained)" >&2
    echo "  and zip it to ${zip_src}, or set PLANG_DESKTOP_ZIP=<path>." >&2
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
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --pretty=%ct)}"
SOURCE_COMMIT="$(git rev-parse HEAD)"
ZIP_SHA="$(sha256sum "${zip}" | awk '{print $1}')"

echo "==> plangOS desktop build"
echo "    branch:        ${BRANCH}"
echo "    image ref:     ${IMAGE_REF}"
echo "    platform:      ${PLATFORM}"
echo "    source commit: ${SOURCE_COMMIT}"
echo "    date epoch:    ${SOURCE_DATE_EPOCH}"
echo "    desktop zip:   sha256:${ZIP_SHA}"

# ---- Resolve digests ---------------------------------------------------------
resolve_digest() {
  local ref="$1" digest
  if ! digest="$(skopeo inspect --format '{{.Digest}}' "docker://${ref}" 2>&1)"; then
    echo "error: skopeo inspect docker://${ref} failed:" >&2
    echo "${digest}" >&2
    return 1
  fi
  [[ "${digest}" =~ ^sha256: ]] || { echo "bad skopeo output: ${digest}" >&2; return 1; }
  printf '%s' "${digest}"
}

RUNTIME_DEPS_DIGEST="$(resolve_digest "${RUNTIME_DEPS_REF}")"
DEBIAN_DIGEST="$(resolve_digest "${DEBIAN_REF}")"
RUNTIME_DEPS_PINNED="${RUNTIME_DEPS_REF%:*}@${RUNTIME_DEPS_DIGEST}"
DEBIAN_PINNED="${DEBIAN_REF%:*}@${DEBIAN_DIGEST}"
echo "    runtime-deps:  ${RUNTIME_DEPS_PINNED}"
echo "    debian:        ${DEBIAN_PINNED}"

# ---- Build -------------------------------------------------------------------
echo "==> podman build"
podman build \
  --platform "${PLATFORM}" \
  --format oci \
  --timestamp "${SOURCE_DATE_EPOCH}" \
  --build-arg "RUNTIME_DEPS_IMAGE=${RUNTIME_DEPS_PINNED}" \
  --build-arg "DEBIAN_IMAGE=${DEBIAN_PINNED}" \
  --build-arg "SOURCE_COMMIT=${SOURCE_COMMIT}" \
  --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
  --tag "${IMAGE_REF}" \
  --file "${SCRIPT_DIR}/Containerfile" \
  "${SCRIPT_DIR}"

# ---- Export WSL distro tarball ----------------------------------------------
# A WSL distro is a plain rootfs tarball. We make one by exporting an
# uncommitted container's filesystem; this is identical in shape to what
# `wsl --import` consumes.
WSL_TAR="${BOT_OUT}/plangos-desktop-wsl.tar"
echo "==> exporting WSL distro tarball -> ${WSL_TAR}"
rm -f "${WSL_TAR}"
CID="$(podman create "${IMAGE_REF}")"
podman export "${CID}" -o "${WSL_TAR}"
podman rm -f "${CID}" >/dev/null
CID=""
WSL_SHA="$(sha256sum "${WSL_TAR}" | awk '{print $1}')"
echo "    wsl tarball:   sha256:${WSL_SHA} ($(du -h "${WSL_TAR}" | awk '{print $1}'))"

# ---- Save OCI archive (for non-WSL distribution) ----------------------------
OCI_TAR="${BOT_OUT}/image.oci.tar"
rm -f "${OCI_TAR}"
podman save --format oci-archive --output "${OCI_TAR}" "${IMAGE_REF}"
OCI_SHA="$(sha256sum "${OCI_TAR}" | awk '{print $1}')"
echo "    oci archive:   sha256:${OCI_SHA}"

# ---- Record ------------------------------------------------------------------
cat > "${BOT_OUT}/build-record.json" <<EOF
{
  "image_ref": "${IMAGE_REF}",
  "source_commit": "${SOURCE_COMMIT}",
  "source_date_epoch": ${SOURCE_DATE_EPOCH},
  "engine": "podman",
  "bases": {
    "runtime_deps": "${RUNTIME_DEPS_PINNED}",
    "debian": "${DEBIAN_PINNED}"
  },
  "inputs": {
    "plang_desktop_zip_sha256": "${ZIP_SHA}"
  },
  "artifacts": {
    "oci_archive": "${OCI_TAR}",
    "oci_archive_sha256": "${OCI_SHA}",
    "wsl_tarball": "${WSL_TAR}",
    "wsl_tarball_sha256": "${WSL_SHA}"
  }
}
EOF

echo "==> done."
echo "    install on Windows: wsl --import plangos C:\\plangos ${WSL_TAR}"
echo "    run:                wsl -d plangos"
