<#
.SYNOPSIS
  Run the plangOS container with the recommended lockdown flags.

.DESCRIPTION
  Invokes 'docker run' directly (Docker Desktop on Windows) with:
    --read-only           immutable rootfs
    --cap-drop=ALL        no Linux capabilities
    --security-opt=no-new-privileges
    --tmpfs /tmp          small writable scratch (noexec, nosuid)
    --user 10001:10001    non-root
    --pids-limit=64       fork-bomb cap
    --rm                  clean up after exit

  Any arguments after -- are passed to plang inside the container. With no
  args, plang runs whatever Start.goal it finds in its working directory
  (/home/plang, baked in from the zip).

.PARAMETER Tag
  Image tag to run. Defaults to the newest 'plang-os:*' tag in the local
  daemon.

.PARAMETER Interactive
  Allocate a TTY and keep stdin open (-it). Needed if plang prompts.

.EXAMPLE
  .\scripts\run.ps1

.EXAMPLE
  .\scripts\run.ps1 -Tag 6e04fbc

.EXAMPLE
  .\scripts\run.ps1 -- --help
#>
[CmdletBinding()]
param(
  [string]$Tag = "",
  [switch]$Interactive,
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$PlangArgs
)

$ErrorActionPreference = "Stop"

# Pick the latest tag if none given.
if (-not $Tag) {
  $Tag = (& docker images plang-os --format "{{.Tag}}" | Select-Object -First 1)
  if (-not $Tag) {
    Write-Error "No plang-os image found. Build first with .\scripts\build.ps1"
    exit 1
  }
}

$image = "plang-os:$Tag"

# Verify the image exists locally.
$exists = (& docker image inspect $image 2>$null)
if ($LASTEXITCODE -ne 0) {
  Write-Error "Image not found: $image"
  exit 1
}

$dockerArgs = @(
  "run", "--rm",
  "--read-only",
  "--cap-drop=ALL",
  "--security-opt=no-new-privileges",
  "--tmpfs", "/tmp:rw,noexec,nosuid,size=64m",
  "--user", "10001:10001",
  "--pids-limit=64"
)
if ($Interactive) { $dockerArgs += "-it" }
$dockerArgs += $image
if ($PlangArgs) { $dockerArgs += $PlangArgs }

Write-Host "==> docker $($dockerArgs -join ' ')"
Write-Host ""

& docker @dockerArgs
exit $LASTEXITCODE
