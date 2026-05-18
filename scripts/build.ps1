<#
.SYNOPSIS
  Build the plangOS rootfs (OCI image + WSL tarball) via podman in WSL.

.DESCRIPTION
  Expects container\plang-amd64.zip to already exist (run
  .\scripts\build-plang-zip.ps1 first).

  Shells into WSL and runs container/build.sh, which:
   - resolves base image digests via skopeo
   - podman build (rootless, in the WSL distro's storage)
   - podman save  -> .bot\<branch>\os\v1\image.oci.tar
   - podman export -> .bot\<branch>\os\v1\plangos-wsl.tar

  Auto-installs podman + skopeo + jq in the WSL distro if missing.

.PARAMETER WslDistro
  WSL distro to build inside. Default: the system default distro.

.EXAMPLE
  .\scripts\build.ps1

.EXAMPLE
  .\scripts\build.ps1 -WslDistro Ubuntu
#>
[CmdletBinding()]
param(
  [string]$WslDistro = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

$buildSh = Join-Path $repoRoot "container\build.sh"
if (-not (Test-Path -LiteralPath $buildSh)) {
  Write-Error "container\build.sh not found under $repoRoot. Is this the plang.os repo?"
  exit 1
}

$zip = Join-Path $repoRoot "container\plang-amd64.zip"
if (-not (Test-Path -LiteralPath $zip)) {
  Write-Error "container\plang-amd64.zip not found. Run .\scripts\build-plang-zip.ps1 first."
  exit 1
}

$wslArgs = @()
if ($WslDistro) { $wslArgs += @("-d", $WslDistro) }

# --- WSL prereqs: podman + skopeo + jq ---------------------------------------
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

$wslRepo = (& wsl @wslArgs --exec wslpath -a "$repoRoot").Trim()
if (-not $wslRepo) { Write-Error "wslpath failed for $repoRoot"; exit 1 }

Write-Host "==> plangOS build (via WSL)"
Write-Host "    repo:      $repoRoot"
Write-Host "    WSL repo:  $wslRepo"
Write-Host "    zip:       container\plang-amd64.zip"
Write-Host ""

# Single-line bash with semicolons. Avoids two PS 5.1 pitfalls:
#   - '&&' is PS 7+ only (PS 5.1 parses it as code even inside strings).
#   - Here-strings carry CRLF line endings; bash parses each line with a
#     trailing '\r' ("invalid option namepefail" etc.).
$bashCmd = "set -eu; cd '$wslRepo'; ./container/build.sh"
& wsl @wslArgs bash -c $bashCmd
if ($LASTEXITCODE -ne 0) {
  Write-Error "build.sh exited with code $LASTEXITCODE"
  exit $LASTEXITCODE
}

Write-Host ""
Write-Host "==> done. Built plang-os images:"
& wsl @wslArgs podman images plang-os
