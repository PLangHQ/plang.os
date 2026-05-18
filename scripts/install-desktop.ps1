<#
.SYNOPSIS
  Register the freshly-built plangOS desktop tarball as a WSL distro.

.DESCRIPTION
  Runs `wsl --import` on the tarball produced by build-desktop.ps1.
  After this, `wsl -d <DistroName>` boots plangOS and (per wsl.conf)
  launches plangd in a window via WSLg.

  Re-running with the same DistroName replaces the existing registration.

.PARAMETER DistroName
  Name to register under. Default: plangos.

.PARAMETER InstallPath
  Where the distro's vhdx lives on disk. Default: C:\plangos.

.PARAMETER TarballPath
  Path to the WSL tarball. Default: looks under
  .bot\<branch>\os\v2\plangos-desktop-wsl.tar.

.EXAMPLE
  .\scripts\install-desktop.ps1

.EXAMPLE
  .\scripts\install-desktop.ps1 -DistroName plangos-dev -InstallPath D:\wsl\plangos-dev
#>
[CmdletBinding()]
param(
  [string]$DistroName = "plangos",
  [string]$InstallPath = "C:\plangos",
  [string]$TarballPath = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

# Discover tarball if not given. We look under .bot/<branch>/os/v2/.
if (-not $TarballPath) {
  $branch = (& git -C $repoRoot rev-parse --abbrev-ref HEAD).Trim()
  $branchDashed = $branch -replace "/", "-"
  $TarballPath = Join-Path $repoRoot ".bot\$branchDashed\os\v2\plangos-desktop-wsl.tar"
}

if (-not (Test-Path -LiteralPath $TarballPath)) {
  Write-Error "tarball not found at: $TarballPath`nRun .\scripts\build-desktop.ps1 first."
  exit 1
}

# If a distro with this name already exists, unregister first. wsl --import
# refuses to overwrite, and replacing in place is what an iterating dev wants.
$existing = (& wsl -l -q) -replace "`0", "" | Where-Object { $_.Trim() -eq $DistroName }
if ($existing) {
  Write-Host "==> unregistering existing distro: $DistroName"
  & wsl --unregister $DistroName
}

if (-not (Test-Path -LiteralPath $InstallPath)) {
  New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

Write-Host "==> wsl --import $DistroName $InstallPath $TarballPath"
& wsl --import $DistroName $InstallPath $TarballPath --version 2
if ($LASTEXITCODE -ne 0) { Write-Error "wsl --import failed"; exit $LASTEXITCODE }

Write-Host ""
Write-Host "==> registered. run with:"
Write-Host "    .\scripts\run-desktop.ps1"
Write-Host "    -- or --"
Write-Host "    wsl -d $DistroName"
