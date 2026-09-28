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
$Plang = Join-Path $Root 'plang\plang.exe'

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
    Expand-Archive $zip -DestinationPath $Root -Force   # plang\, Start.goal, .build\
    Remove-Item $zip
}

# The image must match its manifest before Start.goal may import it.
$manifestPath = Join-Path $Root 'image\manifest-amd64.json'
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $marker   = Join-Path $Root "distro\$($manifest.sha256).imported"
    if (-not (Test-Path $marker)) {   # not imported yet: Start.goal will import it
        $tar = Join-Path $Root "image\$($manifest.file)"
        if (-not (Test-Path $tar)) { Fail "image file missing: $tar" }
        Write-Host "==> Verifying $($manifest.file) ($([math]::Round($manifest.size / 1MB)) MB)" -ForegroundColor Cyan
        $hash = (Get-FileHash $tar -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $manifest.sha256) {
            Fail "image hash does not match the manifest. Not starting.`n  manifest $($manifest.sha256)`n  file     $hash"
        }
    }
}

# Run plang in the folder, which runs Start.goal.
Push-Location $Root
try     { & $Plang @args; $code = $LASTEXITCODE }
finally { Pop-Location }
exit $code
