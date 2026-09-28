# PlangOS launcher for Windows. One job: make sure host plang exists, then run it.
# Host plang runs Start.goal in this folder (WSL, the image, starting PlangOS).
#
#   Local folder:   .\start.ps1                     (e.g. \shared\plangos\start.ps1)
#   From the web:   irm https://plang.is/start.ps1 | iex    (installs to %LOCALAPPDATA%\PlangOS)
#
# Windows PowerShell 5.1 compatible.
#
# Trust: from the web this file is served over TLS and pins the sha256 of the host zip.
# PowerShell 5.1 cannot verify Ed25519, so the pin bridges the gap. From then on, host
# plang verifies everything with our embedded public key.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is ~10x slower with the progress bar

# --- stamped per release by the publish script ---
$Version = '0.0.0'
$Sha256  = '0000000000000000000000000000000000000000000000000000000000000000'
# -------------------------------------------------

# Run from a file: this folder is the install. Piped from the web: %LOCALAPPDATA%\PlangOS.
$Root  = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA 'PlangOS' }
$Plang = Join-Path $Root 'plang\plang.exe'

if (-not (Test-Path $Plang)) {
    if ($PSScriptRoot) { throw "plang not found at $Plang. Is this folder complete?" }
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $file = "plangos-host-win-x64-$Version.zip"
    $zip  = Join-Path $Root $file
    Invoke-WebRequest "https://plang.is/os/$file" -OutFile $zip
    if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $Sha256.ToUpper()) {
        Remove-Item $zip
        throw "Checksum mismatch on $file. Download removed; run again."
    }
    Expand-Archive $zip -DestinationPath $Root -Force   # plang\, Start.goal, .build\
    Remove-Item $zip
}

# Installed: run plang in the folder, which runs Start.goal.
Push-Location $Root
try     { & $Plang @args; $code = $LASTEXITCODE }
finally { Pop-Location }
exit $code
