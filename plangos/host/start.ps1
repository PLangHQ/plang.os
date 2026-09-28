<#
.SYNOPSIS
  PlangOS for Windows: install WSL if needed, import the PlangOS image, start it.

.DESCRIPTION
  For now this script does the work itself. When host plang has its terminal module,
  Start.goal takes over and this script shrinks back to "find plang, run it"
  (start-plang.ps1).

  Run from the PlangOS folder (the one with image\):
    .\start.ps1            install/import if needed, then open PlangOS
    .\start.ps1 -Check     also run the seal and Chromium checks, print PASS/FAIL
    .\start.ps1 -Reset     unregister PlangOS first (deletes its disk), then import fresh

  Windows PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Reset
)
# 'Continue', not 'Stop': in PowerShell 5.1, 'Stop' turns any stderr line from wsl.exe
# into a terminating error. Every native call's exit code is checked explicitly instead.
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'                      # otherwise wsl.exe prints UTF-16

$Distro    = 'PlangOS'
$Root      = $PSScriptRoot
$ImageDir  = Join-Path $Root 'image'
$DistroDir = Join-Path $Root 'distro'
$Stamp     = Join-Path $DistroDir 'image.sha256'   # which image the distro was imported from

function Say($msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# --- 1. WSL ------------------------------------------------------------------------
function Test-Wsl {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    wsl.exe --status *> $null
    return ($LASTEXITCODE -eq 0)
}

if (-not (Test-Wsl)) {
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 19041) { Fail "WSL 2 needs Windows 10 build 19041 or later (this is $build)." }

    Say 'Installing WSL. Windows will ask for administrator rights.'
    $p = Start-Process wsl.exe -ArgumentList '--install', '--no-distribution' -Verb RunAs -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Fail "WSL install failed ($($p.ExitCode)). 0x80370102 means virtualization is off in BIOS/UEFI."
    }
    # come back after the reboot
    $cmd = "powershell.exe -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'PlangOS' -Value $cmd
    Say 'Restart Windows. PlangOS continues when you log back in.'
    exit 0
}

# --- 2. image ----------------------------------------------------------------------
$manifestPath = Join-Path $ImageDir 'manifest-amd64.json'
if (-not (Test-Path $manifestPath)) { Fail "no image found: $manifestPath" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$tarPath  = Join-Path $ImageDir $manifest.file

function Get-Distros {
    (wsl.exe --list --quiet) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
# WSL distro names are case-insensitive, and so is -contains: 'plangos' (the old v1
# Alpine image) counts as 'PlangOS'.
$installed = (Get-Distros) -contains $Distro
$stampSha  = if (Test-Path $Stamp) { (Get-Content $Stamp -Raw).Trim() } else { '' }

if ($installed -and -not $stampSha -and -not $Reset) {
    Fail ("A WSL distro named '$Distro' exists, but this script didn't import it (no $Stamp).`n" +
          "  It may be the old v1 image. Run .\start.ps1 -Reset to replace it (its disk is deleted),`n" +
          "  or remove it yourself: wsl --unregister $Distro")
}

if ($installed -and ($Reset -or ($stampSha -and $stampSha -ne $manifest.sha256))) {
    if ($Reset) { Say "Reset: removing $Distro" }
    else        { Say "New image ($($manifest.version)): replacing $Distro. /home/plang is not carried over yet." }
    wsl.exe --unregister $Distro | Out-Null
    $installed = $false
}

if (-not $installed) {
    Say "Verifying $($manifest.file) ($([math]::Round($manifest.size / 1MB)) MB)"
    if (-not (Test-Path $tarPath)) { Fail "image file missing: $tarPath" }
    $hash = (Get-FileHash $tarPath -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $manifest.sha256) {
        Fail "image hash does not match the manifest. Not importing.`n  manifest $($manifest.sha256)`n  file     $hash"
    }

    Say "Importing $Distro into $DistroDir"
    New-Item -ItemType Directory -Force -Path $DistroDir | Out-Null
    wsl.exe --import $Distro $DistroDir $tarPath --version 2
    if ($LASTEXITCODE -ne 0) {
        # older WSL may not read .tar.xz: decompress to a plain tar with Windows' tar.exe and retry
        Say 'Import of .tar.xz failed; decompressing to .tar and retrying'
        $plainTar = Join-Path $env:TEMP 'plangos-amd64.tar'
        tar.exe -c -f $plainTar --format pax "@$tarPath"
        if ($LASTEXITCODE -ne 0) { Fail 'could not decompress the image with tar.exe' }
        wsl.exe --import $Distro $DistroDir $plainTar --version 2
        $code = $LASTEXITCODE
        Remove-Item $plainTar -ErrorAction SilentlyContinue
        if ($code -ne 0) { Fail "wsl --import failed ($code)" }
    }
    Set-Content -Path $Stamp -Value $manifest.sha256 -NoNewline
    Say "Imported $Distro $($manifest.version)"
}

# --- 3. checks (optional) ----------------------------------------------------------
if ($Check) {
    $results = @()
    function Record($name, $ok, $detail) {
        $script:results += $ok
        $tag = if ($ok) { 'PASS' } else { 'FAIL' }
        $color = if ($ok) { 'Green' } else { 'Red' }
        Write-Host ("{0}  {1}" -f $tag, $name) -ForegroundColor $color
        if ($detail) { Write-Host "      $detail" }
    }
    function Run-In([string[]]$argv) {
        # ToString(): PS 5.1 wraps each stderr line in an ErrorRecord and prints it noisily
        $out = & wsl.exe -d $Distro --exec @argv 2>&1 | ForEach-Object { $_.ToString() } | Out-String
        return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
    }

    $pkgs = Run-In @('/usr/lib/chromium/chromium', '--version')
    $isNew = ($pkgs.Code -eq 0)
    Record 'this distro is the Debian PlangOS image (Chromium present)' $isNew $pkgs.Out
    if (-not $isNew) { Fail "wrong distro under the name $Distro. Run .\start.ps1 -Reset -Check" }

    wsl.exe --terminate $Distro | Out-Null
    $t = Measure-Command { $null = Run-In @('/opt/plang/plang') }
    Record ("1.7 cold start of the distro + plang <= 10 s ({0:N1} s, after terminate)" -f $t.TotalSeconds) ($t.TotalSeconds -le 10) ''

    $r = Run-In @('/bin/sh', '-c', 'echo shell')
    Record '1.4 no shell (/bin/sh must not run)' ($r.Code -ne 0) $r.Out

    $r = Run-In @('cmd.exe', '/c', 'echo interop')
    Record '1.4 interop off (cmd.exe must not run)' ($r.Code -ne 0) $r.Out

    $r = Run-In @('/opt/plang/plang')
    Record 'plang runs as user plang (expects "Not found: /.build/start.pr": app not built yet)' `
        ($r.Out -match 'start\.pr') ($r.Out -split "`n" | Select-Object -Last 2)

    $r = Run-In @('/usr/lib/chromium/chromium', '--headless', '--disable-gpu',
                  '--user-data-dir=/home/plang/.chromium', '--dump-dom',
                  'data:text/html,<h1>hello plangos</h1>')
    $detail = (($r.Out -split "`n") | Where-Object { $_ -match 'hello plangos|sandbox' } | Select-Object -First 3) -join ' | '
    Record 'Chromium renders with its sandbox on (no --no-sandbox)' ($r.Out -match 'hello plangos') $detail

    $failed = ($results | Where-Object { -not $_ }).Count
    Write-Host ''
    Write-Host "$($results.Count - $failed)/$($results.Count) passed. Paste this output to the os bot."
    Write-Host ''
}

# --- 4. open PlangOS ---------------------------------------------------------------
Say "Starting $Distro (plang as user plang, in /home/plang)"
wsl.exe -d $Distro
exit $LASTEXITCODE
