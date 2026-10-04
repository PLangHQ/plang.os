# PlangOS launcher for Windows. Makes sure host plang exists, checks the image, then runs plang,
# which runs Start.goal (WSL install, import, opening PlangOS — through the terminal module).
#
#   Local folder:   .\start.ps1                     (e.g. \shared\plangos\start.ps1)
#   From the web:   irm https://plang.is/start.ps1 | iex    (installs to %LOCALAPPDATA%\PlangOS)
#
# The image's sha256 is checked here for now: on app-systems, file.read returns a reference and
# crypto.hash doesn't give the file's hex sha256 yet, so Start.goal can't check it itself.
# start-direct.ps1 does the whole flow in PowerShell, without plang (fallback).
#
# Windows PowerShell 5.1 compatible.
$ErrorActionPreference = 'Continue'   # 'Stop' turns native stderr into errors in PS 5.1
$ProgressPreference    = 'SilentlyContinue'

# --- stamped per release by the publish script ---
$Version = '0.0.0'
$Sha256  = '0000000000000000000000000000000000000000000000000000000000000000'
# -------------------------------------------------

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# Run from a file: this folder is the install. Piped from the web: %LOCALAPPDATA%\PlangOS.
$Root  = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA 'PlangOS' }
$Plang = Join-Path $Root 'runtime\plang.exe'   # plang.cmd next to this script runs the same one

# A new runtime staged while the old one was running (runtime.new) takes its place now. The one it replaces is kept
# as runtime.prev (the one before that goes): to go back, close PlangOS and rename runtime.prev to runtime.new.
$staged = Join-Path $Root 'runtime.new'
if (Test-Path $staged) {
    $old = Join-Path $Root 'runtime.old'
    if (Test-Path $old) { Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue }
    $current = Join-Path $Root 'runtime'
    try {
        if (Test-Path $current) { Rename-Item $current 'runtime.old' -ErrorAction Stop }
        Rename-Item $staged 'runtime' -ErrorAction Stop
        # say what changed: the runtime comes with its CHANGES.txt (commit, what is new)
        Write-Host ''
        Write-Host '==> NEW PLANG RUNTIME - the old one is replaced' -ForegroundColor Cyan
        $changes = Join-Path $current 'CHANGES.txt'
        if (Test-Path $changes) { Get-Content $changes | ForEach-Object { Write-Host "    $_" } }
        else { Write-Host '    (it came without CHANGES.txt: no notes on what is new)' -ForegroundColor Yellow }
        Write-Host ''
        if (Test-Path $old) {
            $prev = Join-Path $Root 'runtime.prev'
            if (Test-Path $prev) { Remove-Item $prev -Recurse -Force -ErrorAction SilentlyContinue }
            Rename-Item $old 'runtime.prev' -ErrorAction SilentlyContinue
            Write-Host '    The previous runtime is kept in runtime.prev.' -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "The new runtime waits in runtime.new: close PlangOS (plang is still running) and start again." -ForegroundColor Yellow
    }
}

if (-not (Test-Path $Plang)) {
    if ($PSScriptRoot) { Fail "plang not found at $Plang. Is this folder complete?" }
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $file = "plangos-host-win-x64-$Version.zip"
    $zip  = Join-Path $Root $file
    Invoke-WebRequest "https://plang.is/os/$file" -OutFile $zip
    if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $Sha256.ToUpper()) {
        Remove-Item $zip
        Fail "Checksum mismatch on $file. Download removed; run again."
    }
    # runtime\, plang.cmd, Start.goal, .build\, child\ - and data.vhd, the empty data disk (seeded /home/plang,
    # plangos/datadisk/mkdisk.sh). Unpacked beside, then moved in: a data.vhd already here holds the person's
    # files and is never replaced.
    $unpacked = Join-Path $Root '.install'
    if (Test-Path $unpacked) { Remove-Item $unpacked -Recurse -Force }
    Expand-Archive $zip -DestinationPath $unpacked -Force
    $disk = Join-Path $unpacked 'data.vhd'
    if ((Test-Path $disk) -and (Test-Path (Join-Path $Root 'data.vhd'))) { Remove-Item $disk -Force }
    Get-ChildItem $unpacked -Force | ForEach-Object { Move-Item $_.FullName $Root -Force }
    Remove-Item $unpacked -Recurse -Force
    Remove-Item $zip
}

# .goal files open with this plang (double-click runs the goal in its folder), with the plang
# icon. Per user (HKCU\Software\Classes): no administrator rights. Written on every run, so a
# moved folder fixes itself.
function Set-Default([string]$key, [string]$value) {
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name '(default)' -Value $value
}
# An earlier "Open with" choice for .goal (e.g. an older plang runtime) overrides any registration;
# remove it so .goal files open with this plang.
$choice = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.goal\UserChoice'
if (Test-Path $choice) { Remove-Item -Path $choice -Force -ErrorAction SilentlyContinue }
$classes = 'HKCU:\Software\Classes'
$runner  = Join-Path $Root 'run-goal.cmd'
$icon    = Join-Path $Root 'plang.ico'
Set-Default "$classes\.goal" 'PLang.Goal'
Set-Default "$classes\PLang.Goal" 'PLang goal'
Set-Default "$classes\PLang.Goal\DefaultIcon" "`"$icon`""
Set-Default "$classes\PLang.Goal\shell\open\command" "`"$runner`" `"%1`""
Set-Default "$classes\PLang.Goal\shell\edit" 'Edit'
Set-Default "$classes\PLang.Goal\shell\edit\command" "notepad.exe `"%1`""
# tell Explorer the association changed, so icons refresh without a restart
if (-not ('PlangOS.Shell' -as [type])) {
    Add-Type -Namespace PlangOS -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, IntPtr a, IntPtr b);'
}
[PlangOS.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)   # SHCNE_ASSOCCHANGED

# A newer image staged beside the one in use is not used until it is moved into image\: say it is there.
$next = Join-Path $Root 'image.next\manifest-amd64.json'
if (Test-Path $next) {
    $waiting = Get-Content $next -Raw | ConvertFrom-Json
    $inUse   = Join-Path $Root 'image\manifest-amd64.json'
    $using   = if (Test-Path $inUse) { (Get-Content $inUse -Raw | ConvertFrom-Json).sha256 } else { '' }
    if ($waiting.sha256 -ne $using) {
        Write-Host "==> A new PlangOS image waits in image.next ($($waiting.sha256.Substring(0, 8))) - not used yet." -ForegroundColor Yellow
        Write-Host '    Using it replaces PlangOS (your files are kept only on the data disk, data.vhd).' -ForegroundColor Yellow
    }
}

# The image must match its manifest before Start.goal may import it.
$manifestPath = Join-Path $Root 'image\manifest-amd64.json'
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $marker   = Join-Path $Root "distro\$($manifest.sha256).imported"
    if (-not (Test-Path $marker)) {   # not imported yet: Start.goal will import it
        $importing = $true
        $tar = Join-Path $Root "image\$($manifest.file)"
        if (-not (Test-Path $tar)) { Fail "image file missing: $tar" }
        Write-Host ''
        $kept = if (Test-Path (Join-Path $Root 'data.vhd')) { 'your files stay on the data disk' } else { '/home/plang (your files) is not kept' }
        Write-Host "==> NEW PLANGOS IMAGE ($($manifest.sha256.Substring(0, 8))): PlangOS is replaced, $kept" -ForegroundColor Cyan
        Write-Host "==> Verifying $($manifest.file) ($([math]::Round($manifest.size / 1MB)) MB)" -ForegroundColor Cyan
        $hash = (Get-FileHash $tar -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $manifest.sha256) {
            Fail "image hash does not match the manifest. Not starting.`n  manifest $($manifest.sha256)`n  file     $hash"
        }
    }
}

# The data disk: /home/plang (the person's files) on a disk of its own, data.vhd beside this script, so a new
# image never touches it. WSL attaches it to its VM (`wsl --mount --vhd --bare`, which needs administrator
# rights: one UAC prompt, until Windows restarts or WSL shuts down); PlangOS's /etc/fstab mounts it on
# /home/plang when the distro starts. Whether it is in use is asked of PlangOS itself (its mount table).
$dataDisk = Join-Path $Root 'data.vhd'
function Test-DataMounted {
    $mounts = & wsl.exe -d PlangOS -u root -e /usr/bin/mount 2>$null
    return ($LASTEXITCODE -eq 0) -and (($mounts -join "`n") -match ' on /home/plang type ext4')
}
if (Test-Path $dataDisk) {
    if (-not (Test-DataMounted)) {
        Write-Host '==> Attaching the data disk (your files). Windows asks for administrator rights once.' -ForegroundColor Cyan
        try {
            $attach = Start-Process wsl.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
                -ArgumentList @('--mount', '--vhd', "`"$dataDisk`"", '--bare')
            # nonzero is also "already attached": what PlangOS mounts below is the answer
            if ($attach.ExitCode -ne 0) { Write-Host "    wsl --mount said exit $($attach.ExitCode) (it may have been attached already)" -ForegroundColor DarkGray }
        } catch {
            Write-Host "    Not attached: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        # the distro mounts /etc/fstab when it starts: stop it, so the next start mounts the disk
        & wsl.exe --terminate PlangOS 2>$null | Out-Null
        if ($importing) { Write-Host '    The new image mounts it when it starts.' -ForegroundColor Cyan }
        elseif (Test-DataMounted) { Write-Host '    Your files are on the data disk.' -ForegroundColor Cyan }
        else { Write-Host '==> The data disk is not in use: PlangOS starts with the image''s /home/plang (not kept). Your files on data.vhd are untouched.' -ForegroundColor Yellow }
    }
} else {
    Write-Host '==> No data disk (data.vhd): /home/plang is the image''s, and a new image replaces it.' -ForegroundColor Yellow
}

# What runs, said every start: the runtime (the commit from its CHANGES.txt's first line, "plang <commit> (…") and the
# image (its sha256's first 8). Also kept in version.txt, which PlangOS's desktop shows (child/Version.goal).
$notes = Join-Path $Root 'runtime\CHANGES.txt'
$first = if (Test-Path $notes) { Get-Content $notes -TotalCount 1 } else { '' }
$runtimeIs = if ($first -match '^plang (\S+)') { $Matches[1] } else { 'unknown' }
$imageIs   = if ($manifest) { $manifest.sha256.Substring(0, 8) } else { 'none' }
$version   = "plang $runtimeIs, image $imageIs"
[System.IO.File]::WriteAllText((Join-Path $Root 'version.txt'), $version)   # UTF-8 without a BOM (Set-Content's utf8 has one on PowerShell 5)
Write-Host "==> Running $version" -ForegroundColor Cyan

# Run plang in the folder, which runs Start.goal.
Push-Location $Root
try     { & $Plang @args; $code = $LASTEXITCODE }
finally { Pop-Location }
exit $code
