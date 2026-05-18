# plangOS v2 - Desktop variant (WSL distro)

## Context

v1 produced the server container image (Alpine musl, no shell, headless).
v2 adds the desktop variant: same rootfs idea, different base + libs to host
a GUI, packaged as a WSL distro tarball so Windows users run it natively via
`wsl --import` (no Docker Desktop, no podman-inside-WSL).

The architectural pivot: plangOS IS a Linux. On Windows, WSL2 is the natural
hypervisor for a Linux. So the desktop "container" is also a WSL distro.
Same files, different packaging.

## Architecture

Three deliveries from one rootfs build:

| Form          | Use                                          |
| ------------- | -------------------------------------------- |
| OCI image     | Linux desktops, CI, future appliance work    |
| WSL tarball   | Windows users (the primary v2 target)        |
| (Appliance)   | v3+ - boots on dedicated hardware            |

Build pipeline:
1. `container-desktop/build.sh` does `podman build` (rootfs assembly).
2. Same image is `podman export`ed to a tar -> `plangos-desktop-wsl.tar`.
3. `podman save --format oci-archive` produces the OCI archive in parallel.

## Decisions

| Area               | Choice                            | Why                                                              |
| ------------------ | --------------------------------- | ---------------------------------------------------------------- |
| Base               | Debian slim (`debian:12-slim`)    | Photino.Native + WebKitGTK pin to glibc; musl was a rathole      |
| Renderer           | WebKitGTK 4.1 via Photino.NET     | cross-platform, in-process, native window via WSLg on Windows    |
| Windowing          | WSLg (Wayland/X via WSL2)         | zero Windows-side install; same image works on bare Linux        |
| Binary name        | `plangd` (desktop variant)        | distinct from headless `plang`; clarifies intent                 |
| Lockdown           | same as v1: no shell, no apt, UID 10001, read-only root | consistent across artifacts                |
| Distribution form  | WSL tarball + OCI archive         | both fall out of one `podman build`                              |

## Files produced

- `container-desktop/Containerfile` - Debian slim + WebKitGTK, sift app files into /home/plang, leave os/ at /opt/plang
- `container-desktop/build.sh` - podman build + WSL tarball export + OCI archive
- `container-desktop/wsl.conf` - WSL distro config (boot command = plangd, default user plang, interop disabled)
- `container-desktop/.dockerignore` - context restricted to Containerfile + wsl.conf + zip
- `scripts/build-desktop.ps1` - Windows entry: WSL-invokes the bash build
- `scripts/install-desktop.ps1` - `wsl --import` wrapper (unregisters existing distro first)
- `scripts/run-desktop.ps1` - `wsl -d plangos`
- `.bot/os-v1-container/os/v2/plan.md` (this file)

## PLang-side dependency (NOT in this repo)

This image needs a Photino-based PLang variant. PLang currently only ships:
- `PlangConsole` (headless CLI)
- `PlangWindowForms` (Windows-only: WinForms + WebView2)

For v2, PLang needs a new project (e.g. `PlangDesktop`) that:
- Targets `net10.0` (cross-platform, not `net10.0-windows`)
- References `Photino.NET` (NuGet) instead of Microsoft.Web.WebView2
- Compiles to assembly name `plangd`
- ~30-60 lines of glue: open Photino window, load HTML, hand off to PLang's pipeline

That work is in the plang repo, not plang.os. Once it lands, this image's
desktop zip is produced by:

```sh
dotnet publish PlangDesktop/PlangDesktop.csproj \
  -c Release -r linux-x64 --self-contained true \
  -p:InvariantGlobalization=true \
  -o publish-desktop
# add os/, Start.goal, .build/ alongside
# zip -> plang-desktop-amd64.zip
```

## Verification (once PLang side lands)

1. `.\scripts\build-desktop.ps1` produces `plangos-desktop-wsl.tar` in `.bot/<branch>/os/v2/`.
2. `.\scripts\install-desktop.ps1` registers as `plangos` distro.
3. `.\scripts\run-desktop.ps1` opens a window on the Windows desktop showing PLang's HTML UI.
4. `wsl --shutdown` + re-run -> still works (cold start).
5. Window survives alt-tab, can be moved, resized.

## Out of scope (v3+)

- Bootable appliance variant (ISO + kernel + dm-verity).
- macOS support (no WSLg equivalent - would use native Photino on Mac).
- Custom seccomp / AppArmor profiles.
- Photino on musl (would shave ~25 MB but requires building Photino.Native from source).
