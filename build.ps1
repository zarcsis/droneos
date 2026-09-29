<#
.SYNOPSIS
    Build the DroneOS Raspberry Pi image on Windows.

.DESCRIPTION
    rpi-image-gen (the submodule that does the real work) is Linux-only: it
    needs mmdebstrap, mount/user namespaces and an arm64 binfmt handler. This
    wrapper therefore runs build.sh - the actual build script - inside Linux:

      * Docker Desktop (default). Builds the droneos-builder image from
        docker/Dockerfile (Debian trixie + every rpi-image-gen dependency),
        registers the arm64 QEMU handler in the Docker VM when it is missing,
        and runs the build in a privileged container. The checkout is mounted
        read-only at /src, the work tree lives in the named volume droneos-work
        (kept between runs: built host tools, apt cache, rootfs), and the
        finished image is copied to out\.

      * WSL (-Wsl). Runs build.sh natively in a Debian/Ubuntu WSL distro. The
        first run installs the host packages with sudo (password prompt).
        Sources on /mnt/c are staged into ~/.cache/droneos because mmdebstrap
        cannot build on drvfs.

    Nothing is installed on Windows itself. Docker Desktop is started when it
    is installed but not running.

    NOTE on comment-based help: every .PARAMETER description MUST start on the
    line AFTER the ".PARAMETER <Name>" tag, otherwise Get-Help renders it empty.

.PARAMETER Config
    Config file to build (default: droneos.yaml next to this script).

.PARAMETER Out
    Directory that receives the finished .img (default: out\ next to this script).

.PARAMETER Wsl
    Run build.sh natively inside a WSL distro instead of Docker Desktop.

.PARAMETER Distro
    WSL distro for -Wsl (default: the WSL default distro). Must be Debian-based.

.PARAMETER FsOnly
    Build the filesystem only, skip image generation (rpi-image-gen -f).

.PARAMETER ImageOnly
    Skip the filesystem, only (re)generate the image (rpi-image-gen -i).

.PARAMETER Interactive
    Let rpi-image-gen ask before each stage (rpi-image-gen -I). Needs a terminal.

.PARAMETER Clean
    Remove the rootfs, image and deploy directories of this config; the built
    host tools and the apt cache stay.

.PARAMETER Purge
    Docker: delete the droneos-work volume. WSL: delete ~/.cache/droneos/work.

.PARAMETER Rebuild
    Docker: rebuild the builder image from scratch (--pull --no-cache).

.PARAMETER Shell
    Docker: open an interactive shell in the builder container instead of
    building (the checkout is at /src, the work volume at /work).

.PARAMETER NoAptCache
    Do not keep downloaded .debs between builds.

.PARAMETER Set
    rpi-image-gen variable overrides, KEY=VALUE, repeatable or comma-separated
    (alias -D): -Set IGconf_device_user1pass=Fo0bar!! -Set IGconf_device_hostname=drone

.PARAMETER DryRun
    Print the docker / wsl command that would run, then exit.

.PARAMETER Help
    Show this help and exit (-h / -Help).

.PARAMETER Passthru
    Any extra raw flags are appended to build.sh verbatim (see ./build.sh --help).

.EXAMPLE
    .\build.ps1
    Build droneos.yaml in Docker Desktop; the image lands in out\.

.EXAMPLE
    .\build.ps1 -Set IGconf_device_user1pass=Fo0bar!!
    Same, with a login password for the first user.

.EXAMPLE
    .\build.ps1 -Wsl -Distro Debian
    Build natively inside the WSL "Debian" distro.

.EXAMPLE
    .\build.ps1 -Shell
    Poke around in the builder container (rpi-image-gen at /work/src/rpi-image-gen after a build).
#>
[CmdletBinding()]
param(
    [string]$Config = 'droneos.yaml',
    [string]$Out,

    [switch]$Wsl,
    [string]$Distro,

    [switch]$FsOnly,
    [switch]$ImageOnly,
    [switch]$Interactive,
    [switch]$Clean,
    [switch]$Purge,
    [switch]$Rebuild,
    [switch]$Shell,
    [switch]$NoAptCache,

    [Alias('D')]
    [string[]]$Set,

    [switch]$DryRun,

    [Alias('h')]
    [switch]$Help,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Passthru
)

# ---- Re-launch under PowerShell 7+ when started from Windows PowerShell 5.1 --
# 5.1 turns native stderr into terminating errors under $ErrorActionPreference
# 'Stop' and mangles BOM-less UTF-8; docker/wsl output would trip it.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) {
        foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe",
                         "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe")) {
            if (Test-Path $c) { $pwshExe = $c; break }
        }
    }
    if (-not $pwshExe) {
        Write-Host "ERROR: build.ps1 needs PowerShell 7+. Install it:  winget install Microsoft.PowerShell" -ForegroundColor Red
        exit 1
    }
    Write-Host "Re-launching under PowerShell 7 ($pwshExe)..." -ForegroundColor Cyan
    & $pwshExe -NoProfile -File $PSCommandPath @args
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help -Detailed $PSCommandPath
    return
}

# ---- Locate the checkout ------------------------------------------------- #
$Root = $PSScriptRoot
foreach ($f in @('build.sh', 'droneos.yaml', 'docker\Dockerfile', 'docker\entrypoint.sh')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $f))) {
        throw "$f not found next to build.ps1 ($Root) - is this the droneos checkout?"
    }
}

# rpi-image-gen submodule (the container mounts /src read-only, so fetch it here)
if (-not (Test-Path -LiteralPath (Join-Path $Root 'rpi-image-gen\rpi-image-gen'))) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "rpi-image-gen submodule is missing and git is not on PATH. Run: git submodule update --init --recursive"
    }
    Write-Host "Fetching the rpi-image-gen submodule..." -ForegroundColor Cyan
    & git -C $Root submodule update --init --recursive rpi-image-gen
    if ($LASTEXITCODE -or -not (Test-Path -LiteralPath (Join-Path $Root 'rpi-image-gen\rpi-image-gen'))) {
        throw "git submodule update failed"
    }
}

# Config: relative paths are taken from the checkout, not from the cwd.
$cfgPath = if ([System.IO.Path]::IsPathRooted($Config)) { $Config } else { Join-Path $Root $Config }
$cfgPath = [System.IO.Path]::GetFullPath($cfgPath)
if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) { throw "Config not found: $cfgPath" }

$outPath = if ($Out) { $Out } else { Join-Path $Root 'out' }
$outPath = [System.IO.Path]::GetFullPath($outPath).TrimEnd('\')

# Version tag for rpi-image-gen's deploy-<version> directory. Computed here
# because inside the container/WSL the bind-mounted index always looks dirty.
$Version = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
    $Version = (& git -C $Root describe --tags --always --dirty 2>$null | Select-Object -First 1)
}
if (-not $Version) { $Version = Get-Date -Format 'yyyy-MM-dd' }

# ---- build.sh arguments shared by both back ends ------------------------- #
$shArgs = [System.Collections.Generic.List[string]]::new()
if ($FsOnly)      { $shArgs.Add('--fs-only') }
if ($ImageOnly)   { $shArgs.Add('--image-only') }
if ($Interactive) { $shArgs.Add('--interactive') }
if ($Clean)       { $shArgs.Add('--clean') }
if ($Purge)       { $shArgs.Add('--purge') }
if ($NoAptCache)  { $shArgs.Add('--no-apt-cache') }
if ($Passthru)    { $Passthru | Where-Object { $_ } | ForEach-Object { $shArgs.Add($_) } }

$overrides = @()
foreach ($item in @($Set)) {
    foreach ($kv in ($item -split ',')) {
        $kv = $kv.Trim()
        if (-not $kv) { continue }
        if ($kv -notmatch '^[A-Za-z_][A-Za-z0-9_]*=') {
            throw "-Set expects KEY=VALUE (e.g. -Set IGconf_device_user1pass=secret), got '$kv'"
        }
        $overrides += $kv
    }
}
if ($overrides) { $shArgs.Add('--'); $overrides | ForEach-Object { $shArgs.Add($_) } }

$haveTty = -not ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)
if ($Interactive -and -not $haveTty) { throw "-Interactive needs an interactive terminal" }

# Deterministic Windows -> WSL path (/mnt/<drive>/...). No wslpath: its result
# depends on the distro's mount config; the /mnt/<drive> drvfs mount is always there.
function ConvertTo-WslPath([string]$Path) {
    $full  = [System.IO.Path]::GetFullPath($Path)
    $drive = $full.Substring(0, 1).ToLower()
    $rest  = $full.Substring(2) -replace '\\', '/'
    return "/mnt/$drive$rest"
}

function Show-Result {
    if ($FsOnly -or $Clean -or $Purge -or $Shell) { return }
    $imgs = Get-ChildItem -LiteralPath $outPath -Filter '*.img' -ErrorAction SilentlyContinue
    if ($imgs) {
        Write-Host ""
        Write-Host "Image(s):" -ForegroundColor Green
        foreach ($i in $imgs) {
            Write-Host ("  {0,8:N0} MB  {1}" -f ($i.Length / 1MB), $i.FullName)
        }
        Write-Host "Flash with Raspberry Pi Imager -> 'Use custom'." -ForegroundColor Green
    }
}

# =========================================================================== #
#                                   WSL                                        #
# =========================================================================== #
if ($Wsl) {
    if ($Shell) { throw "-Shell is a Docker option; for WSL just run:  wsl.exe -d <distro>" }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe not found. Install WSL (wsl --install -d Debian) or drop -Wsl to use Docker Desktop."
    }

    # build.sh must be LF inside Linux; a Windows checkout may have CRLF, so run
    # a normalised copy from %TEMP% and tell it where the real checkout is.
    $content = [System.IO.File]::ReadAllText((Join-Path $Root 'build.sh'))
    $tmpScript = Join-Path ([System.IO.Path]::GetTempPath()) 'droneos-build.sh'
    [System.IO.File]::WriteAllText($tmpScript, $content.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

    $linuxScript = ConvertTo-WslPath $tmpScript
    $linuxRoot   = ConvertTo-WslPath $Root
    $linuxCfg    = ConvertTo-WslPath $cfgPath
    $linuxOut    = ConvertTo-WslPath $outPath

    $wslArgs = [System.Collections.Generic.List[string]]::new()
    if ($Distro) { $wslArgs.Add('-d'); $wslArgs.Add($Distro) }
    $wslArgs.Add('-e'); $wslArgs.Add('bash'); $wslArgs.Add($linuxScript)
    $wslArgs.Add('-c'); $wslArgs.Add($linuxCfg)
    $wslArgs.Add('-o'); $wslArgs.Add($linuxOut)
    $shArgs | ForEach-Object { $wslArgs.Add($_) }

    if ($DryRun) {
        Write-Host "DRY RUN - would execute (DRONEOS_ROOT=$linuxRoot DRONEOS_VERSION=$Version via WSLENV):" -ForegroundColor Yellow
        Write-Host "  wsl.exe $($wslArgs -join ' ')"
        return
    }

    # Hand the checkout path and the version over as environment (WSLENV).
    $prevWslEnv = $env:WSLENV
    $prevRoot   = $env:DRONEOS_ROOT
    $prevVer    = $env:DRONEOS_VERSION
    try {
        $env:DRONEOS_ROOT    = $linuxRoot
        $env:DRONEOS_VERSION = $Version
        $parts = @()
        if ($env:WSLENV) {
            $parts = $env:WSLENV -split ':' | Where-Object { $_ -and $_ -notin @('DRONEOS_ROOT', 'DRONEOS_VERSION') }
        }
        $env:WSLENV = (@($parts) + @('DRONEOS_ROOT', 'DRONEOS_VERSION')) -join ':'

        Write-Host "Building in WSL$(if ($Distro) { " ($Distro)" })..." -ForegroundColor Cyan
        & wsl.exe @wslArgs
        $code = $LASTEXITCODE
    }
    finally {
        $env:WSLENV = $prevWslEnv
        if ($null -eq $prevRoot) { Remove-Item Env:DRONEOS_ROOT -ErrorAction SilentlyContinue }    else { $env:DRONEOS_ROOT = $prevRoot }
        if ($null -eq $prevVer)  { Remove-Item Env:DRONEOS_VERSION -ErrorAction SilentlyContinue } else { $env:DRONEOS_VERSION = $prevVer }
    }
    if ($code -eq 0) { Show-Result }
    exit $code
}

# =========================================================================== #
#                               Docker Desktop                                 #
# =========================================================================== #
$ImageTag   = if ($env:DRONEOS_BUILDER_IMAGE) { $env:DRONEOS_BUILDER_IMAGE } else { 'droneos-builder:trixie' }
$WorkVolume = if ($env:DRONEOS_WORK_VOLUME)   { $env:DRONEOS_WORK_VOLUME }   else { 'droneos-work' }

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker not found on PATH. Install Docker Desktop (winget install Docker.DockerDesktop) or use -Wsl."
}

function Test-DockerReady {
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

if (-not (Test-DockerReady)) {
    $dd = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (-not (Test-Path -LiteralPath $dd)) {
        throw "The docker daemon is not reachable and Docker Desktop is not installed at '$dd'. Start your Docker engine or use -Wsl."
    }
    Write-Host "Docker Desktop is not running - starting it..." -ForegroundColor Yellow
    Start-Process -FilePath $dd | Out-Null
    $deadline = (Get-Date).AddSeconds(180)
    while (-not (Test-DockerReady)) {
        if ((Get-Date) -gt $deadline) { throw "Docker Desktop did not come up within 3 minutes." }
        Start-Sleep -Seconds 5
    }
}

# Config path as the container sees it (/src is the checkout; anything outside
# gets its own read-only mount at /cfg).
$mounts = @('-v', "${Root}:/src:ro", '-v', "${WorkVolume}:/work", '-v', "${outPath}:/out")
$rootPrefix = $Root.TrimEnd('\') + '\'
if ($cfgPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    $cfgInside = '/src/' + ($cfgPath.Substring($rootPrefix.Length) -replace '\\', '/')
} else {
    $cfgDir = Split-Path -Parent $cfgPath
    $mounts += @('-v', "${cfgDir}:/cfg:ro")
    $cfgInside = '/cfg/' + (Split-Path -Leaf $cfgPath)
}

$inner = [System.Collections.Generic.List[string]]::new()
$inner.Add('--in-container'); $inner.Add('-B'); $inner.Add('/work'); $inner.Add('-o'); $inner.Add('/out')
$inner.Add('-c'); $inner.Add($cfgInside)
$shArgs | Where-Object { $_ -ne '--purge' } | ForEach-Object { $inner.Add($_) }

$envs = @('-e', 'DRONEOS_IN_CONTAINER=1', '-e', 'DRONEOS_ROOT=/src', '-e', "DRONEOS_VERSION=$Version", '-e', 'TERM=xterm-256color')
if ($env:SOURCE_DATE_EPOCH) { $envs += @('-e', "SOURCE_DATE_EPOCH=$($env:SOURCE_DATE_EPOCH)") }

$runArgs = @('run', '--rm', '-i')
if ($haveTty) { $runArgs += '-t' }
$runArgs += @('--privileged', '--hostname', 'droneos-builder') + $envs + $mounts

if ($DryRun) {
    Write-Host "DRY RUN - would execute:" -ForegroundColor Yellow
    Write-Host "  docker build -t $ImageTag $(Join-Path $Root 'docker')"
    if ($Purge)      { Write-Host "  docker volume rm -f $WorkVolume"; return }
    if ($Shell)      { Write-Host "  docker $($runArgs -join ' ') --entrypoint bash $ImageTag"; return }
    Write-Host "  docker $($runArgs -join ' ') $ImageTag $($inner -join ' ')"
    return
}

if ($Purge) {
    Write-Host "Removing work volume $WorkVolume..." -ForegroundColor Yellow
    & docker volume rm -f $WorkVolume | Out-Null
    if ($LASTEXITCODE) { throw "docker volume rm failed ($LASTEXITCODE)" }
    Write-Host "Done." -ForegroundColor Green
    return
}

# Builder image (cached; -Rebuild forces a clean rebuild).
Write-Host "Builder image $ImageTag..." -ForegroundColor Cyan
$bargs = @('build', '-t', $ImageTag)
if ($Rebuild) { $bargs += @('--pull', '--no-cache') }
$bargs += (Join-Path $Root 'docker')
& docker @bargs
if ($LASTEXITCODE) { throw "docker build failed ($LASTEXITCODE)" }

# arm64 binfmt handler in the Docker VM kernel. Docker Desktop does not register
# it by default (arm64 containers fail with 'exec format error'); tonistiigi/binfmt
# installs qemu-aarch64 with the F flag so it also works inside the chroot.
# It does not survive a VM restart, hence the check on every run.
$arch = (& docker info --format '{{.Architecture}}' 2>$null | Select-Object -First 1)
if ($arch -notmatch '^(aarch64|arm64)') {
    & docker run --rm --privileged --entrypoint sh $ImageTag -c 'mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc; test -e /proc/sys/fs/binfmt_misc/qemu-aarch64' *> $null
    if ($LASTEXITCODE) {
        Write-Host "Registering the arm64 QEMU binfmt handler in the Docker VM (tonistiigi/binfmt)..." -ForegroundColor Cyan
        & docker run --rm --privileged tonistiigi/binfmt --install arm64
        if ($LASTEXITCODE) { throw "binfmt registration failed ($LASTEXITCODE)" }
    }
}

if ($Shell) {
    if (-not $haveTty) { throw "-Shell needs an interactive terminal" }
    & docker @runArgs --entrypoint bash $ImageTag
    exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $outPath)) { New-Item -ItemType Directory -Path $outPath | Out-Null }

Write-Host "Building in Docker ($ImageTag, work volume $WorkVolume)..." -ForegroundColor Cyan
& docker @runArgs $ImageTag @inner
$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Host "Build failed (exit $code)." -ForegroundColor Red
    exit $code
}
Show-Result
exit 0
