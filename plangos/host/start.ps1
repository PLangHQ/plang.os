# PlangOS launcher for Windows. One job: make sure host plang exists, then run start.goal.
#   irm https://plang.is/start.ps1 | iex
#
# Everything else (WSL, the image, the container, the screen, terminal requests)
# lives in start.goal, run by host plang.
# Windows PowerShell 5.1 compatible.
#
# Trust: this file is served fresh from plang.is over TLS and pins the sha256 of this
# release's host plang zip. PowerShell 5.1 cannot verify Ed25519, so the pin bridges the
# gap. From here on, host plang verifies everything with our embedded public key.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is ~10x slower with the progress bar

# --- stamped per release by the publish script ---
$Version = '0.0.0'
$Sha256  = @{
    amd64 = '0000000000000000000000000000000000000000000000000000000000000000'
    arm64 = '0000000000000000000000000000000000000000000000000000000000000000'
}
# -------------------------------------------------

$Home_ = Join-Path $env:LOCALAPPDATA 'PlangOS'
$Arch  = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$Host_ = Join-Path $Home_ 'host'
$Plang = Join-Path $Host_ 'plang.exe'

if (-not (Test-Path $Plang)) {
    New-Item -ItemType Directory -Force -Path $Host_ | Out-Null
    $file = "plang-host-win-$Arch-$Version.zip"
    $zip  = Join-Path $Home_ $file
    Invoke-WebRequest "https://plang.is/os/$file" -OutFile $zip
    if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $Sha256[$Arch].ToUpper()) {
        Remove-Item $zip
        throw "Checksum mismatch on $file. Download removed; run again."
    }
    Expand-Archive $zip -DestinationPath $Host_ -Force
    Remove-Item $zip
}

# Host plang updates itself (verified with our key) from start.goal.
& $Plang --path (Join-Path $Host_ 'os') start @args
exit $LASTEXITCODE
