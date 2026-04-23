<#
.SYNOPSIS
  Build the plangOS container image via WSL.

.DESCRIPTION
  Shells into WSL and runs container/build.sh with PLANG_ZIP pointed at a
  Windows-side copy of the PLang self-contained publish zip. The zip lives
  outside the repo because it is too big (about 260 MB).

  Uses podman inside WSL (no Docker Desktop dependency). The image is stored
  in the WSL distro's rootless podman store. To list images from Windows:
    wsl podman images
  To run:
    .\scripts\run.ps1

  Prereq in the WSL distro:
    sudo apt update && sudo apt install -y podman skopeo jq

.PARAMETER PlangZip
  Windows path to the PLang self-contained publish zip. Default:
  C:\plang-amd64.zip

.PARAMETER WslDistro
  WSL distro to use. Default: the system default distro.

.EXAMPLE
  .\scripts\build.ps1

.EXAMPLE
  .\scripts\build.ps1 -PlangZip "D:\builds\plang-amd64.zip"
#>
[CmdletBinding()]
param(
  [string]$PlangZip = "C:\plang-amd64.zip",
  [string]$WslDistro = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $PlangZip)) {
  Write-Error "PLang zip not found at: $PlangZip. Pass -PlangZip <path> or place the zip at C:\plang-amd64.zip."
  exit 1
}

# scripts\build.ps1 -> repo root
$repoRoot = Split-Path -Parent $PSScriptRoot

# Validate this is the plang.os repo.
$buildSh = Join-Path $repoRoot "container\build.sh"
if (-not (Test-Path -LiteralPath $buildSh)) {
  Write-Error "container\build.sh not found under $repoRoot. Is this the plang.os repo?"
  exit 1
}

# --- WSL arg plumbing --------------------------------------------------------
$wslArgs = @()
if ($WslDistro) { $wslArgs += @("-d", $WslDistro) }

# --- WSL prereqs: podman + skopeo + jq ---------------------------------------
# Check each tool, collect missing ones, apt-install them together.
$tools   = @("podman", "skopeo", "jq")
$missing = @()
foreach ($t in $tools) {
  & wsl @wslArgs bash -c "command -v $t >/dev/null 2>&1"
  if ($LASTEXITCODE -ne 0) { $missing += $t }
}
if ($missing.Count -gt 0) {
  Write-Host "==> installing in WSL: $($missing -join ' ')"
  Write-Host "    (you may be prompted for your WSL sudo password)"
  & wsl @wslArgs sudo apt-get update -qq
  if ($LASTEXITCODE -ne 0) { Write-Error "apt-get update failed"; exit 1 }
  $installArgs = @("sudo", "apt-get", "install", "-y", "--no-install-recommends") + $missing
  & wsl @wslArgs @installArgs
  if ($LASTEXITCODE -ne 0) { Write-Error "apt-get install failed for: $($missing -join ' ')"; exit 1 }
  Write-Host "==> installed."
  Write-Host ""
}

# Convert Windows paths to WSL paths. 'wsl --exec wslpath' bypasses the shell
# so paths with spaces survive.
$wslZip  = (& wsl @wslArgs --exec wslpath -a "$PlangZip").Trim()
if (-not $wslZip)  { Write-Error "wslpath failed for $PlangZip"; exit 1 }
$wslRepo = (& wsl @wslArgs --exec wslpath -a "$repoRoot").Trim()
if (-not $wslRepo) { Write-Error "wslpath failed for $repoRoot"; exit 1 }

Write-Host "==> plangOS build (via WSL)"
Write-Host "    repo:       $repoRoot"
Write-Host "    WSL repo:   $wslRepo"
Write-Host "    plang zip:  $PlangZip"
Write-Host "    WSL zip:    $wslZip"
Write-Host ""

# Single-line bash with semicolons. Avoids two PS 5.1 pitfalls:
#   - '&&' is PS 7+ only (PS 5.1 parses it as code even inside strings).
#   - Here-strings carry CRLF line endings on Windows, which bash parses as
#     trailing '\r' on every line ("invalid option namepefail" etc.).
$bashCmd = "set -eu; cd '$wslRepo'; export PLANG_ZIP='$wslZip'; ./container/build.sh"

& wsl @wslArgs bash -c $bashCmd
if ($LASTEXITCODE -ne 0) {
  Write-Error "build.sh exited with code $LASTEXITCODE"
  exit $LASTEXITCODE
}

Write-Host ""
Write-Host "==> done. Built plang-os images:"
& wsl @wslArgs podman images plang-os
