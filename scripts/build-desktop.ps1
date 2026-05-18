<#
.SYNOPSIS
  Build the plangOS desktop image via WSL. Produces a WSL distro tarball.

.DESCRIPTION
  Runs container-desktop/build.sh inside WSL. The result is:
    .bot/<branch>/os/v2/plangos-desktop-wsl.tar
  which is consumable by 'wsl --import' on Windows.

  Prereqs in the WSL distro: podman, skopeo, jq (auto-installed if missing).

.PARAMETER PlangDesktopZip
  Windows path to the desktop zip (linux-x64 self-contained publish of the
  Photino-based plang variant + os/ + Start.goal + .build). Default:
  C:\plang-desktop-amd64.zip

.PARAMETER WslDistro
  WSL distro to build inside. Default: system default.

.EXAMPLE
  .\scripts\build-desktop.ps1

.EXAMPLE
  .\scripts\build-desktop.ps1 -PlangDesktopZip D:\builds\plang-desktop-amd64.zip
#>
[CmdletBinding()]
param(
  [string]$PlangDesktopZip = "C:\plang-desktop-amd64.zip",
  [string]$WslDistro = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $PlangDesktopZip)) {
  Write-Error "Desktop zip not found at: $PlangDesktopZip"
  exit 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildSh = Join-Path $repoRoot "container-desktop\build.sh"
if (-not (Test-Path -LiteralPath $buildSh)) {
  Write-Error "container-desktop\build.sh not found under $repoRoot"
  exit 1
}

$wslArgs = @()
if ($WslDistro) { $wslArgs += @("-d", $WslDistro) }

# Auto-install WSL prereqs.
$tools   = @("podman", "skopeo", "jq")
$missing = @()
foreach ($t in $tools) {
  & wsl @wslArgs bash -c "command -v $t >/dev/null 2>&1"
  if ($LASTEXITCODE -ne 0) { $missing += $t }
}
if ($missing.Count -gt 0) {
  Write-Host "==> installing in WSL: $($missing -join ' ')"
  & wsl @wslArgs sudo apt-get update -qq
  if ($LASTEXITCODE -ne 0) { Write-Error "apt-get update failed"; exit 1 }
  $installArgs = @("sudo", "apt-get", "install", "-y", "--no-install-recommends") + $missing
  & wsl @wslArgs @installArgs
  if ($LASTEXITCODE -ne 0) { Write-Error "apt-get install failed"; exit 1 }
}

$wslZip  = (& wsl @wslArgs --exec wslpath -a "$PlangDesktopZip").Trim()
$wslRepo = (& wsl @wslArgs --exec wslpath -a "$repoRoot").Trim()

Write-Host "==> plangOS desktop build (via WSL)"
Write-Host "    repo:        $repoRoot"
Write-Host "    WSL repo:    $wslRepo"
Write-Host "    desktop zip: $PlangDesktopZip"
Write-Host "    WSL zip:     $wslZip"
Write-Host ""

$bashCmd = "set -eu; cd '$wslRepo'; export PLANG_DESKTOP_ZIP='$wslZip'; ./container-desktop/build.sh"
& wsl @wslArgs bash -c $bashCmd
if ($LASTEXITCODE -ne 0) {
  Write-Error "build.sh exited with code $LASTEXITCODE"
  exit $LASTEXITCODE
}

Write-Host ""
Write-Host "==> next: register as WSL distro"
Write-Host "    .\scripts\install-desktop.ps1"
