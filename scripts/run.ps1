<#
.SYNOPSIS
  Run plangOS by entering the registered WSL distro.

.DESCRIPTION
  Just `wsl -d <DistroName>`. WSL reads /etc/wsl.conf inside the distro,
  sees `[boot] command = /opt/plang/plang`, and runs plang directly.
  No container engine at runtime; no Docker; no podman run.

  Build first with .\scripts\build.ps1, then register with
  .\scripts\install.ps1, then this script.

.PARAMETER DistroName
  Distro to run. Default: plangos.

.EXAMPLE
  .\scripts\run.ps1

.EXAMPLE
  .\scripts\run.ps1 -DistroName plangos-dev
#>
[CmdletBinding()]
param(
  [string]$DistroName = "plangos"
)

$ErrorActionPreference = "Stop"

$existing = (& wsl -l -q) -replace "`0", "" | Where-Object { $_.Trim() -eq $DistroName }
if (-not $existing) {
  Write-Error "Distro '$DistroName' not registered. Run .\scripts\install.ps1 first."
  exit 1
}

Write-Host "==> wsl -d $DistroName"
& wsl -d $DistroName
exit $LASTEXITCODE
