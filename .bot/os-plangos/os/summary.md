# os bot — branch `os/plangos`

## Version
v1. The first PlangOS image, stage 1 of `/shared/os/start.md`.

## What this is
PlangOS is the Linux half of "one link on plang.is". Host plang on Windows imports this image into WSL and starts it. Inside is Debian 13 with self-contained plang and Chromium, sealed from Windows: interop off, no `/mnt/c`, no shell, and nothing that can become root.

This branch replaces the v2 Photino/WebKitGTK desktop idea (branch `os/v1-container`) with Chromium, as Ingi decided on 2026-09-28. The Alpine no-shell image in `container/` stays as the headless server image.

## What was done
- **`plangos/`** (new):
  - `build.sh` has two commands. `lock` resolves `packages.conf` against snapshot.debian.org into `packages.lock`. `image` assembles the rootfs with `dpkg-deb -x` (no install scripts), generates caches through unprivileged chroots, adds plang and `/etc`, and writes a deterministic `.tar.xz` plus a manifest.
  - `mktar.py` writes the deterministic tar and refuses setuid files.
  - `checks.py` covers checks 1.4 and 1.6, plus confirming every ELF finds its libraries.
  - `run-local.sh` runs the rootfs as uid 10001 via pivot_root.
  - `tardiff.py` diagnoses check 1.5.
  - `rootfs/etc/` holds wsl.conf, passwd, group and nsswitch.
  - `host/start.ps1` is the draft from `/shared/os`.
  - `dev/import.ps1` lets you test on Windows before host plang exists.
- **Results:**
  - 224.3 MB xz: PASS.
  - Two builds are byte-identical: PASS.
  - checks.py 14/14.
  - plang starts in 1.4–2.5 s.
  - Chromium renders headless as uid 10001 with its sandbox on.
- **Key decisions** (see `v1/tradeoffs.md`):
  - Build without a container runtime or root.
  - Deny Mesa: 192 MB, since Chromium renders on the CPU.
  - xz, because gzip is 326 MB.
  - No `[boot] command`.
  - `/home/plang` is the only user tree.
- **Plan updated:** the `/shared/os/start.md` stage 1 results table.

## Next
1. **Ingi on Windows:** build or copy `out/`, run `dev/import.ps1`, `wsl -d PlangOS` → checks 1.4 (WSL half) and 1.7.
2. **A built `Start.goal` for the image.** The pre-built `.pr` files in `app-systems` are outdated (`PrFormatOutdated`), so it needs `plang build` with an LLM.
3. **Remaining checks:**
   - CVE scan (trivy/grype);
   - SBOM (syft);
   - manifest signing, which waits on PLang's signature format for host plang.
4. **PLang-side (coder):**
   - `terminal`;
   - `container`/Service keepalive;
   - channel framing;
   - the cross-channel goal call.
   Host plang's `start.goal` can't run until these exist.

## Open for Ingi
- Does plang drive Chromium through Playwright? If not, drop the Node copy (−44 MB).
- The old `container-desktop/` and `scripts/*-desktop.ps1` (the v2 Photino desktop) are superseded. OK to delete?

## Code example
```sh
plangos/build.sh image /tmp/plang-publish      # -> out/plangos-amd64.tar.xz + manifest-amd64.json
python3 plangos/checks.py plangos/.work/rootfs plangos/out/plangos-amd64.tar.xz
plangos/run-local.sh plangos/.work/rootfs /usr/lib/chromium/chromium --headless --disable-gpu --dump-dom 'data:text/html,<h1>hi</h1>'
```
