<#
.SYNOPSIS
  Build C:\plang-amd64.zip from a local PLang source checkout.

.DESCRIPTION
  Produces the input zip that scripts\build.ps1 consumes. Does everything
  in one shot:

    1. dotnet publish PlangConsole -r linux-musl-x64 (the binary that ends
       up in the plangOS image)
    2. dotnet publish PlangConsole -r win-x64 (used only on this machine to
       run 'plang build' on Start.goal so the .pr is baked in)
    3. Copy plang\os\ into the linux publish (plang's stdlib lives at
       {execPath}\os)
    4. Run win-x64 plang.exe to build Start.goal -> produces .build\start.pr
    5. Drop Start.goal + .build\ into the linux publish
    6. Compress to one zip

  Strips .playwright (~530 MB of bundled Node + driver) by default since
  Start.goal doesn't need a browser. Pass -IncludePlaywright to keep it.

.PARAMETER PlangRepoPath
  Path to the PLang source checkout. Default: ..\plang next to plang.os.

.PARAMETER OutputZipPath
  Where the final zip goes. Default: C:\plang-amd64.zip (the path
  scripts\build.ps1 defaults to).

.PARAMETER IncludePlaywright
  Keep the bundled Playwright/Node payload. Use only if Start.goal (or any
  goal that ships in the image) needs browser automation.

.EXAMPLE
  .\scripts\build-plang-zip.ps1

.EXAMPLE
  .\scripts\build-plang-zip.ps1 -PlangRepoPath D:\src\plang
#>
[CmdletBinding()]
param(
  [string]$PlangRepoPath = "",
  [string]$OutputZipPath = "C:\plang-amd64.zip",
  [switch]$IncludePlaywright
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

# Default: assume plang source is a sibling of plang.os.
if (-not $PlangRepoPath) {
  $PlangRepoPath = Join-Path (Split-Path -Parent $repoRoot) "plang"
}
$PlangRepoPath = (Resolve-Path -LiteralPath $PlangRepoPath).Path

$consoleCsproj = Join-Path $PlangRepoPath "PlangConsole\PLangConsole.csproj"
$plangOsDir    = Join-Path $PlangRepoPath "os"
$startGoal     = Join-Path $repoRoot "Start.goal"

foreach ($p in @($consoleCsproj, $plangOsDir, $startGoal)) {
  if (-not (Test-Path -LiteralPath $p)) {
    Write-Error "missing: $p"
    exit 1
  }
}

# Working dirs in TEMP. Wipe and recreate each run.
$buildDir     = Join-Path $env:TEMP "plangos-build"
$linuxPublish = Join-Path $buildDir "linux-musl-x64"
$winPublish   = Join-Path $buildDir "win-x64"
$workDir      = Join-Path $buildDir "work"

if (Test-Path -LiteralPath $buildDir) {
  Remove-Item -Recurse -Force -LiteralPath $buildDir
}
New-Item -ItemType Directory -Path $buildDir,$workDir | Out-Null

Write-Host "==> Build-PlangZip"
Write-Host "    plang repo:   $PlangRepoPath"
Write-Host "    output zip:   $OutputZipPath"
Write-Host "    work dir:     $buildDir"
Write-Host ""

# --- Step 1: linux-musl-x64 publish (the binary the image runs) -------------
Write-Host "==> dotnet publish linux-musl-x64 ..."
& dotnet publish $consoleCsproj `
    -c Release -r linux-musl-x64 --self-contained true `
    -p:InvariantGlobalization=true `
    -o $linuxPublish `
    --nologo --verbosity:quiet
if ($LASTEXITCODE -ne 0) { Write-Error "linux publish failed"; exit $LASTEXITCODE }

# --- Step 2: win-x64 publish (only to run plang build on this machine) ------
Write-Host "==> dotnet publish win-x64 ..."
& dotnet publish $consoleCsproj `
    -c Release -r win-x64 --self-contained true `
    -p:InvariantGlobalization=true `
    -o $winPublish `
    --nologo --verbosity:quiet
if ($LASTEXITCODE -ne 0) { Write-Error "win publish failed"; exit $LASTEXITCODE }

# --- Step 3: copy os/ next to BOTH binaries (plang looks at {execPath}\os) --
Write-Host "==> copy os/ alongside both binaries"
Copy-Item -Recurse -LiteralPath $plangOsDir -Destination (Join-Path $linuxPublish "os")
Copy-Item -Recurse -LiteralPath $plangOsDir -Destination (Join-Path $winPublish   "os")

# --- Step 4: run plang.exe build on Start.goal ------------------------------
Write-Host "==> plang.exe build (runs locally to produce .pr)"
Copy-Item -LiteralPath $startGoal -Destination $workDir
Push-Location -LiteralPath $workDir
try {
  & (Join-Path $winPublish "plang.exe") build --app='{"create":true}'
  if ($LASTEXITCODE -ne 0) { Write-Error "plang build failed"; exit $LASTEXITCODE }
} finally {
  Pop-Location
}

if (-not (Test-Path -LiteralPath (Join-Path $workDir ".build\start.pr"))) {
  Write-Error "plang build did not produce .build\start.pr; check above output"
  exit 1
}

# --- Step 5: drop Start.goal + .build into the linux publish ----------------
Copy-Item -LiteralPath (Join-Path $workDir "Start.goal") -Destination $linuxPublish
Copy-Item -Recurse -LiteralPath (Join-Path $workDir ".build") -Destination $linuxPublish

# --- Strip .playwright unless asked to keep --------------------------------
$playwrightDir = Join-Path $linuxPublish ".playwright"
if ((Test-Path -LiteralPath $playwrightDir) -and (-not $IncludePlaywright)) {
  Write-Host "==> removing bundled .playwright (~530 MB) - pass -IncludePlaywright to keep"
  Remove-Item -Recurse -Force -LiteralPath $playwrightDir
}

# --- Step 6: zip -----------------------------------------------------------
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
