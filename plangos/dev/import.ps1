<#
.SYNOPSIS
  Dev only: register a built PlangOS image as a WSL distro, without host plang.

.DESCRIPTION
  Stands in for start.goal until host plang has its terminal and container modules.
  Verifies the tarball against manifest-amd64.json, replaces any existing
  registration, imports it, and prints what to run next.

  Windows PowerShell 5.1 compatible. Needs WSL already installed (wsl --install).

.EXAMPLE
  .\plangos\dev\import.ps1 -Dir \\wsl$\Ubuntu\home\me\plang.os\plangos\out
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$Dir,          # folder with plangos-amd64.tar.xz + manifest-amd64.json
  [string]$Name        = 'PlangOS',
  [string]$InstallPath = (Join-Path $env:LOCALAPPDATA 'PlangOS\distro')
)
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'   # otherwise wsl.exe prints UTF-16

$manifest = Get-Content (Join-Path $Dir 'manifest-amd64.json') -Raw | ConvertFrom-Json
$tar      = Join-Path $Dir $manifest.file
$hash     = (Get-FileHash $tar -Algorithm SHA256).Hash.ToLower()
if ($hash -ne $manifest.sha256) { throw "sha256 mismatch on $tar`n  manifest $($manifest.sha256)`n  file     $hash" }
Write-Host "verified $($manifest.file) ($([math]::Round($manifest.size / 1MB)) MB, $hash)"

if ((wsl.exe --list --quiet) -contains $Name) {
  Write-Host "unregistering existing $Name"
  wsl.exe --unregister $Name | Out-Null
}
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
wsl.exe --import $Name $InstallPath $tar --version 2
if ($LASTEXITCODE -ne 0) { throw "wsl --import failed ($LASTEXITCODE). 0x80370102 = virtualization off in BIOS/UEFI." }

Write-Host ""
Write-Host "Imported. Try:"
Write-Host "  wsl -d $Name                  # starts plang (the passwd shell) in /home/plang"
Write-Host "  wsl -d $Name -- /bin/sh       # should FAIL: there is no shell"
Write-Host "  wsl --terminate $Name"
