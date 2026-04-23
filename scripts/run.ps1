<#
.SYNOPSIS
  Run the plangOS container with the recommended lockdown flags.

.DESCRIPTION
  Invokes 'podman run' inside WSL with:
    --read-only           immutable rootfs
    --cap-drop=ALL        no Linux capabilities
    --security-opt=no-new-privileges
    --tmpfs /tmp          small writable scratch (noexec, nosuid)
    --user 10001:10001    non-root
    --pids-limit=64       fork-bomb cap
    --rm                  clean up after exit

  Docker Desktop is NOT required. Podman must be installed in the WSL distro
  (see scripts\build.ps1). Images built by scripts\build.ps1 live in the WSL
  podman store; they are not visible to Windows 'docker' or 'podman.exe'.

  Any args after -- are passed to plang inside the container. With no args,
  plang runs whatever Start.goal it finds in its working directory
  (/home/plang, baked in from the zip).

.PARAMETER Tag
  Image tag to run. Defaults to the newest 'plang-os:*' tag in the WSL podman
  store.

.PARAMETER Interactive
  Allocate a TTY and keep stdin open (-it). Needed if plang prompts.

.PARAMETER WslDistro
  WSL distro to use. Default: system default.

.EXAMPLE
  .\scripts\run.ps1

.EXAMPLE
  .\scripts\run.ps1 -Tag 60ceee1

.EXAMPLE
  .\scripts\run.ps1 -- --help
#>
[CmdletBinding()]
param(
  [string]$Tag = "",
  [switch]$Interactive,
  [string]$WslDistro = "",
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$PlangArgs
)

$ErrorActionPreference = "Stop"

$wslArgs = @()
if ($WslDistro) { $wslArgs += @("-d", $WslDistro) }

# Pick the newest plang-os tag if none given.
if (-not $Tag) {
  $Tag = (& wsl @wslArgs podman images plang-os --format "{{.Tag}}" | Select-Object -First 1)
  if (-not $Tag) {
    Write-Error "No plang-os image found in WSL podman store. Build first with .\scripts\build.ps1"
    exit 1
  }
}

$image = "plang-os:$Tag"

$podmanArgs = @(
  "run", "--rm",
  "--read-only",
  "--cap-drop=ALL",
  "--security-opt=no-new-privileges",
  "--tmpfs", "/tmp:rw,noexec,nosuid,size=64m",
  "--user", "10001:10001",
  "--pids-limit=64"
)
if ($Interactive) { $podmanArgs += "-it" }
$podmanArgs += $image
if ($PlangArgs) { $podmanArgs += $PlangArgs }

Write-Host "==> wsl podman $($podmanArgs -join ' ')"
Write-Host ""

& wsl @wslArgs podman @podmanArgs
exit $LASTEXITCODE
