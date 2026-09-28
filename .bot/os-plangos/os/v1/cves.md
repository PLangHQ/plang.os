# CVE scan — PlangOS v1 image (2026-09-28)

Tools: syft 1.52.0, grype 0.119.0 (vuln DB built 2026-09-28T06:42Z), both checksum-verified
releases. Run with `plangos/scan.sh <rootfs> <out>`. Total: 320 findings
(4 Critical, 78 High, 123 Medium, 19 Low, 94 Negligible, 2 Unknown). Many CVEs repeat
across the packages built from one source (util-linux → libblkid/libmount/libuuid/…).

To make Debian packages visible to scanners, the image ships `/var/lib/dpkg/status`
(metadata only, no dpkg). Without it, scanners see only the .NET parts.

## By source

| Source | Critical/High | Fix | Owner |
|---|---|---|---|
| Playwright's bundled **Node 22.13.1** (`/opt/plang/.playwright/node/linux-x64/node`) | 1 C, ~12 H (29 total) | Node ≥ 22.23.2 via a newer `Microsoft.Playwright`, or **drop Playwright's Node from the image** (−44 MB) | Ingi: does plang drive Chromium through Playwright? |
| **Scriban.Signed 6.2.1** | 1 C, 8 H | 7.2.0 | PLang (coder): package bump |
| **MessagePack 3.1.3** | 3 H | 3.1.7 | PLang (coder) |
| **SixLabors.ImageSharp 2.0.0** | 3 H | 2.1.10 | PLang (coder) |
| **SQLitePCLRaw.lib.e_sqlite3 2.1.10** | 1 H | none listed | PLang (coder): watch |
| Debian 13: libxml2 (1 C), libtiff6 (1 C), util-linux libs, expat, libc6, cups, X11 libs, zlib/minizip, ncurses, libsndfile, libacl | 2 C, 48 H | **none yet** in trixie at snapshot `20260928T000000Z` | os: move the snapshot date as Debian ships fixes (`build.sh lock`) |
| krb5 (binary match) | 4 H | — | Likely false positives (includes CVE-2007-*), from binary matching on libkrb5 |

## What the seal changes
Nothing in PlangOS runs as root, there is no shell, and nothing listens. A library CVE
needs a way in: a malicious page rendered by Chromium (sandboxed), or input that plang
parses (Scriban templates, MessagePack data, images). The .NET findings are the ones in
plang's own input path, so the PLang package bumps matter most.

## Recommended next
1. PLang: bump Scriban → 7.2.0, MessagePack → 3.1.7, ImageSharp → 2.1.10 (coder task on `app-systems`).
2. Decide Playwright: drop its Node (−44 MB, −29 findings), or bump `Microsoft.Playwright`.
3. os: rerun `scan.sh` on each build; move the Debian snapshot date when fixes appear.
