<#
.SYNOPSIS
  Run plangOS desktop. Opens a windowed plangd via WSLg.

.DESCRIPTION
  Just `wsl -d <DistroName>`. WSL reads /etc/wsl.conf inside the distro, sees
  `[boot] command = /opt/plang/plangd`, and runs it. WSLg routes the window to
  the Windows desktop automatically - no Docker, no podman, no extra flags.

.PARAMETER DistroName
  Distro to run. Default: plangos.

.EXAMPLE
  .\scripts\run-desktop.ps1
#>
[CmdletBinding()]
param(
  [string]$DistroName = "plangos"
)

$ErrorActionPreference = "Stop"

$existing = (& wsl -l -q) -replace "`0", "" | Where-Object { $_.Trim() -eq $DistroName }
if (-not $existing) {
  Write-Error "Distro '$DistroName' not registered. Run .\scripts\install-desktop.ps1 first."
  exit 1
}

Write-Host "==> wsl -d $DistroName"
& wsl -d $DistroName
exit $LASTEXITCODE
