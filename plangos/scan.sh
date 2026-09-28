#!/usr/bin/env bash
# SBOM + CVE scan of a built PlangOS rootfs (attack-surface checklist: SBOM, CVEs).
#
#   plangos/scan.sh <rootfs-dir> <out-dir>
#
# Writes <out-dir>/plangos-amd64.spdx.json (syft) and cves.txt / cves.json (grype).
# Needs syft and grype on PATH (release binaries from github.com/anchore; verify their
# checksums.txt). Exit code 0 even with findings: this reports, it doesn't gate.
#
# --distro debian:13 is passed explicitly: a directory scan doesn't follow the relative
# /etc/os-release symlink, and without the distro grype can't match Debian packages
# against Debian's security tracker (it silently reports none).
set -euo pipefail
ROOT="$1"; OUT="$2"
mkdir -p "$OUT"
export GRYPE_DB_CACHE_DIR="${GRYPE_DB_CACHE_DIR:-$OUT/.grype-db}"

syft scan "dir:$ROOT" -q -o "spdx-json=$OUT/plangos-amd64.spdx.json"
grype "dir:$ROOT" --distro debian:13 -q -o json  > "$OUT/cves.json"
grype "dir:$ROOT" --distro debian:13 -q -o table > "$OUT/cves.txt"

echo "SBOM: $OUT/plangos-amd64.spdx.json"
echo "CVEs: $OUT/cves.txt ($(($(wc -l < "$OUT/cves.txt") - 1)) findings)"
for s in Critical High Medium Low Negligible Unknown; do
  printf '  %-10s %s\n' "$s" "$(grep -c " $s" "$OUT/cves.txt" || true)"
done
