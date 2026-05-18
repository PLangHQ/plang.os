<#
.SYNOPSIS
  Build C:\plang-amd64.zip from a local PLang source checkout.

.DESCRIPTION
  Produces the input zip that scripts\build.ps1 consumes. Does just four
  things:

    1. dotnet publish PlangConsole -r linux-musl-x64 (the binary the image runs)
    2. Copy plang\os\ next to the binary (plang's stdlib lives at {execPath}\os)
    3. Copy Start.goal + the pre-built .build\ from this repo
    4. Compress to one zip

  The .build\start.pr is committed in this repo (1 KB JSON, output of an
  earlier `plang build`). That means no LLM call at zip-build time and no
  need for a win-x64 publish on this machine. If you edit Start.goal,
  regenerate the .pr with `plang build` and commit it.

  Strips .playwright (~530 MB of bundled Node + driver) by default since
  Start.goal does not need a browser. Pass -IncludePlaywright to keep it.

.PARAMETER PlangRepoPath
  Path to the PLang source checkout. Default: ..\plang next to plang.os.

.PARAMETER OutputZipPath
  Where the final zip goes. Default: <repo>\container\plang-amd64.zip
  (the path build.sh picks up from the build context with no extra config).

.PARAMETER IncludePlaywright
  Keep the bundled Playwright/Node payload.

.EXAMPLE
  .\scripts\build-plang-zip.ps1

.EXAMPLE
  .\scripts\build-plang-zip.ps1 -PlangRepoPath D:\src\plang
#>
[CmdletBinding()]
param(
  [string]$PlangRepoPath = "",
  [string]$OutputZipPath = "",
  [switch]$IncludePlaywright
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

# Default output: container/plang-amd64.zip inside this repo. build.sh finds
# it there via its preflight, no PLANG_ZIP env var needed.
if (-not $OutputZipPath) {
  $OutputZipPath = Join-Path $repoRoot "container\plang-amd64.zip"
}

if (-not $PlangRepoPath) {
  $PlangRepoPath = Join-Path (Split-Path -Parent $repoRoot) "plang"
}
$PlangRepoPath = (Resolve-Path -LiteralPath $PlangRepoPath).Path

$consoleCsproj = Join-Path $PlangRepoPath "PlangConsole\PLangConsole.csproj"
$plangOsDir    = Join-Path $PlangRepoPath "os"
$startGoal     = Join-Path $repoRoot "Start.goal"
$prebuilt      = Join-Path $repoRoot ".build"
$prFile        = Join-Path $prebuilt "start.pr"

foreach ($p in @($consoleCsproj, $plangOsDir, $startGoal, $prFile)) {
  if (-not (Test-Path -LiteralPath $p)) {
    Write-Error "missing: $p"
    exit 1
  }
}

$buildDir     = Join-Path $env:TEMP "plangos-build"
$linuxPublish = Join-Path $buildDir "linux-musl-x64"

if (Test-Path -LiteralPath $buildDir) {
  Remove-Item -Recurse -Force -LiteralPath $buildDir
}
New-Item -ItemType Directory -Path $buildDir | Out-Null

Write-Host "==> Build-PlangZip"
Write-Host "    plang repo:   $PlangRepoPath"
Write-Host "    output zip:   $OutputZipPath"
Write-Host "    work dir:     $buildDir"
Write-Host ""

# --- Step 1: linux-musl-x64 publish -----------------------------------------
Write-Host "==> dotnet publish linux-musl-x64 ..."
& dotnet publish $consoleCsproj `
    -c Release -r linux-musl-x64 --self-contained true `
    -p:InvariantGlobalization=true `
    -o $linuxPublish `
    --nologo --verbosity:quiet
if ($LASTEXITCODE -ne 0) { Write-Error "linux publish failed"; exit $LASTEXITCODE }

# --- Step 2: copy os/ next to the binary ------------------------------------
Write-Host "==> copy os/ alongside the binary"
Copy-Item -Recurse -LiteralPath $plangOsDir -Destination (Join-Path $linuxPublish "os")

# --- Step 3: drop Start.goal + pre-built .build/ into the publish -----------
Write-Host "==> copy Start.goal + .build/ from repo"
Copy-Item -LiteralPath $startGoal -Destination $linuxPublish
Copy-Item -Recurse -LiteralPath $prebuilt -Destination (Join-Path $linuxPublish ".build")

# --- Strip .playwright unless asked to keep --------------------------------
$playwrightDir = Join-Path $linuxPublish ".playwright"
if ((Test-Path -LiteralPath $playwrightDir) -and (-not $IncludePlaywright)) {
  Write-Host "==> removing bundled .playwright (~530 MB)"
  Remove-Item -Recurse -Force -LiteralPath $playwrightDir
}

# --- Step 4: zip -----------------------------------------------------------
Write-Host "==> Compress-Archive -> $OutputZipPath"
if (Test-Path -LiteralPath $OutputZipPath) {
  Remove-Item -Force -LiteralPath $OutputZipPath
}
Compress-Archive `
  -Path (Join-Path $linuxPublish "*") `
  -DestinationPath $OutputZipPath `
  -CompressionLevel Optimal -Force

$sizeMB = [math]::Round((Get-Item -LiteralPath $OutputZipPath).Length / 1MB, 1)
Write-Host ""
Write-Host "==> done."
Write-Host "    $OutputZipPath  ($sizeMB MB)"
Write-Host ""
Write-Host "    next: .\scripts\build.ps1"
