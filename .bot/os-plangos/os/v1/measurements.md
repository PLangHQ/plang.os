# Measurements — PlangOS v1 image (2026-09-28)

Build box: 8 cores, 11 GB RAM, Ubuntu 22.04, no root. Inputs: plang `app-systems`
@ `91f8093`, Debian snapshot `20260928T000000Z`, `packages.lock` (220 packages).

## Size
| | |
|---|---|
| **plangos-amd64.tar.xz** | **224.3 MB** (check 1.6: ≤ 300 MB → PASS) |
| same tar, gzip -9 | 326.4 MB (would FAIL) |
| uncompressed tar | 842 MB (first build, before Mesa was denied) |
| first build, with Mesa, gzip | 397.6 MB |

Uncompressed rootfs breakdown (final):
| Part | Size |
|---|---|
| `/usr/lib/chromium` (chromium binary alone: 312 MB) | ~353 MB |
| `/opt/plang` (runtime 166 MB + Playwright Node 115 MB + `os/` 51 MB) | ~331 MB |
| `/usr/lib/x86_64-linux-gnu` without Mesa | ~94 MB |
| `/usr/share` (icons 18 MB, X11 6 MB, gtk 4 MB, fonts 3 MB, zoneinfo 2 MB) | ~36 MB |

Compressed shares (gzip, for comparison): Playwright Node ≈ 44 MB, plang `os/` ≈ 11 MB.

## Reproducibility (check 1.5)
- Two clean image builds (fresh work dirs) → identical `sha256 d148f01b9ac2b287f3c4877e85c43e82b857f71d0a3d8437100b22dff06f055d` → **PASS**.
- The first attempt differed in exactly one entry, `/var/cache/ldconfig/aux-cache` (inode and ctime records). It's now removed at build time.
- plang publish, clean `bin/obj` twice: **0 differing files** (Deterministic + ContinuousIntegrationBuild).
- The hash moves with the git commit, because `SOURCE_DATE_EPOCH` = the last commit time. Same commit → same bytes.

## Runtime (in `run-local.sh`, uid 10001, Linux namespaces; not WSL)
| | |
|---|---|
| plang start → reads app, reports missing `start.pr` | 2.5 s cold, 1.4–1.5 s warm |
| Chromium headless `--disable-gpu`, sandbox on, `--dump-dom` of a data: URL | renders `<h1>hello plangos</h1>`, exit 0 |
| Chromium noise | dbus connection errors (no dbus in PlangOS). Harmless. |

## Build time
~5.5 min per image (xz -9 on 4 threads is most of it); `lock` ~1 min; plang publish ~2 min.

## On Ingi's Windows (2026-09-28, `start.ps1 -Reset -Check`, 6/6)
| | |
|---|---|
| `wsl --import` of the `.tar.xz` | worked directly (no tar.exe fallback) |
| 1.7 cold start, `wsl --terminate` → plang running | **1.9 s** |
| `/bin/sh` | `execvpe(/bin/sh) failed: No such file or directory` |
| `cmd.exe` | `execvpe(cmd.exe) failed: No such file or directory` |
| plang as user plang | `NotFound (404): Not found: /.build/start.pr` (expected; the app isn't built) |
| Chromium 154.0.8037.57, headless, sandbox on | `<html><head></head><body><h1>hello plangos</h1></body></html>` |
| `mount -a` warning (seen with the old v1 image) | gone (`mountFsTab = false`) |

## Not measured yet
Checks 1.1–1.3, 1.7 and 1.8: WSL install and reboot, tamper refusal by host plang, cold start in WSL, update keeping data. Idle RSS in WSL.
