<#
.SYNOPSIS
  Register the freshly-built plangOS WSL tarball as a WSL distro.

.DESCRIPTION
  Runs `wsl --import` on the tarball produced by build.ps1. After this,
  `wsl -d <DistroName>` boots plangOS and runs plang directly (per the
  /etc/wsl.conf baked into the image).

  Re-running with the same DistroName replaces the existing registration.

.PARAMETER DistroName
  Name to register under. Default: plangos.

.PARAMETER InstallPath
  Where the distro's vhdx lives on disk. Default: C:\plangos.

.PARAMETER TarballPath
  Path to the WSL tarball. Default: looks under
  .bot\<branch>\os\v1\plangos-wsl.tar.

.EXAMPLE
  .\scripts\install.ps1

.EXAMPLE
  .\scripts\install.ps1 -DistroName plangos-dev -InstallPath D:\wsl\plangos-dev
#>
[CmdletBinding()]
param(
  [string]$DistroName = "plangos",
  [string]$InstallPath = "C:\plangos",
  [string]$TarballPath = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $TarballPath) {
  $branch = (& git -C $repoRoot rev-parse --abbrev-ref HEAD).Trim()
  $branchDashed = $branch -replace "/", "-"
  $TarballPath = Join-Path $repoRoot ".bot\$branchDashed\os\v1\plangos-wsl.tar"
}

if (-not (Test-Path -LiteralPath $TarballPath)) {
  Write-Error "tarball not found at: $TarballPath`nRun .\scripts\build.ps1 first."
  exit 1
}

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
Write-Host "    .\scripts\run.ps1"
