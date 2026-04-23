<#
.SYNOPSIS
  Build the plangOS container image via WSL.

.DESCRIPTION
  Shells into WSL and runs container/build.sh with PLANG_ZIP pointed at a
  Windows-side copy of the PLang self-contained publish zip. The zip lives
  outside the repo because it is too big (about 260 MB).

  Docker Desktop (with WSL integration) is assumed. The image is built by the
  WSL-side docker client, which talks to the same Docker Desktop daemon that
  Windows PowerShell uses, so after building you can run 'docker run' or
  'docker images' from either side and see the image.

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

# Build the bash command as a here-string to avoid PowerShell parsing issues.
# 'set -e' makes any failing line abort the script, which replaces the need
# for '&&' chaining (which is not supported in Windows PowerShell 5.1).
$bashCmd = @"
set -euo pipefail
cd '$wslRepo'
export PLANG_ZIP='$wslZip'
./container/build.sh
"@

& wsl @wslArgs bash -c $bashCmd
if ($LASTEXITCODE -ne 0) {
  Write-Error "build.sh exited with code $LASTEXITCODE"
  exit $LASTEXITCODE
}

Write-Host ""
Write-Host "==> done. Built plang-os images:"
& docker images plang-os
