<#
.SYNOPSIS
    Build the DroneOS Raspberry Pi image on Windows.

.DESCRIPTION
    rpi-image-gen (the submodule that does the real work) is Linux-only: it
    needs mmdebstrap, mount/user namespaces and an arm64 binfmt handler. This
    wrapper therefore runs build.sh - the actual build script - inside Linux:

      * Docker Desktop (default). Builds the droneos-builder image from
        docker/Dockerfile (Debian trixie + every rpi-image-gen dependency),
        makes sure the Docker VM can run arm64 binaries, and runs the build in
        a privileged container. The checkout is mounted read-only at /src, the
        work tree lives in the named volume droneos-work (kept between runs:
        built host tools, apt cache, the last rootfs), and the finished image
        is copied to out\.

      * WSL (-Wsl). Runs build.sh natively in a Debian/Ubuntu WSL distro. The
        first run installs the host packages with sudo (password prompt).
        Sources on /mnt/c are staged into ~/.cache/droneos because mmdebstrap
        cannot build on drvfs. A checkout that lives inside a distro
        (\\wsl.localhost\<distro>\...) is built there, in place.

    Before building, both back ends prove that Linux sees the checkout, the
    config and the out folder - a mapped network drive or a subst drive is not
    visible there - so a build does not fail at the very end.

    Nothing is installed on Windows itself. Docker Desktop is started when it
    is installed but not running. Needs PowerShell 7.3 or newer; Windows
    PowerShell 5.1 re-launches the script in pwsh.

    NOTE on comment-based help: every .PARAMETER description MUST start on the
    line AFTER the ".PARAMETER <Name>" tag, otherwise Get-Help renders it empty.

.PARAMETER Config
    Config file to build (default: droneos.yaml next to this script). A plain
    relative path is taken from the checkout; ~ and drive-qualified paths work
    as usual.

.PARAMETER Out
    Folder that receives the finished .img (default: out\ next to this script).
    Must be on a local drive.

.PARAMETER Wsl
    Run build.sh natively inside a WSL distro instead of Docker Desktop.

.PARAMETER Distro
    WSL distro for -Wsl (default: the WSL default distro). Must be Debian-based.

.PARAMETER Deps
    WSL: install / upgrade the host packages (sudo) and exit.
    Docker: refresh the builder image (pull the base image) and exit.

.PARAMETER FsOnly
    Build the filesystem only, skip image generation (rpi-image-gen -f).

.PARAMETER ImageOnly
    Skip the filesystem and regenerate the image (rpi-image-gen -i) from the
    filesystem of the last successful full or -FsOnly build of the same config,
    even if the checkout has changed since.

.PARAMETER Interactive
    Let rpi-image-gen ask before each stage (rpi-image-gen -I). Needs a terminal.

.PARAMETER Clean
    Delete the built rootfs, image and deploy directories from the work tree;
    the built host tools, the apt cache and the keys stay. (A successful build
    already deletes those of older versions by itself.)

.PARAMETER Purge
    Docker: delete the droneos-work volume. WSL: delete the work tree
    (~/.cache/droneos/work for a checkout on a Windows drive).

.PARAMETER Rebuild
    Docker: rebuild the builder image from scratch (--pull --no-cache).

.PARAMETER Shell
    Docker: open an interactive shell in the builder container instead of
    building (the checkout is at /src, the work volume at /work).

.PARAMETER NoAptCache
    Do not keep downloaded .debs between builds.

.PARAMETER Set
    rpi-image-gen variable overrides as KEY=VALUE, several separated by commas
    (alias -D):  -Set IGconf_device_hostname=drone7,IGconf_device_user1sudo=passwd
    A comma starts a new pair only where KEY= follows it (spaces after the comma
    are fine), so a value may contain commas. Bare KEY=VALUE words without -Set
    work as well. Do NOT use a "--" separator: pwsh -File treats it as an
    (empty) parameter name.
    For a login password give a hash in single quotes,
    -Set 'IGconf_device_user1passhash=$6$...', not IGconf_device_user1pass: a
    plain password ends up in the work tree and in the deploy set. Make the
    hash with the builder image:
        docker run --rm -it --entrypoint openssl droneos-builder:trixie passwd -6

.PARAMETER DryRun
    Print the docker / wsl command that would run, then exit. Starts nothing.

.PARAMETER Help
    Show this help and exit (-h / -Help).

.PARAMETER Passthru
    Bare KEY=VALUE overrides (comma lists work as with -Set) and --no-fix-perms
    (WSL: do not chmod o+x the parents of the work tree) are passed on to
    build.sh. Any other word is rejected, so a typo cannot slip past -Purge:
    --dry-run is -DryRun here.

.EXAMPLE
    .\build.ps1
    Build droneos.yaml in Docker Desktop; the image lands in out\.

.EXAMPLE
    .\build.ps1 -Set 'IGconf_device_hostname=drone7,IGconf_device_user1passhash=$6$...'
    Same, with a host name and a login password (hash, see -Set).

.EXAMPLE
    .\build.ps1 -Wsl -Distro Debian
    Build natively inside the WSL "Debian" distro.

.EXAMPLE
    .\build.ps1 -Shell
    Poke around in the builder container (rpi-image-gen at /work/src/rpi-image-gen after a build).
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Config = 'droneos.yaml',
    [string]$Out,

    [switch]$Wsl,
    [string]$Distro,

    [switch]$Deps,
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

    # [object[]], not [string[]]: an unquoted a=1,b=2 next to other bare words
    # arrives as an array, which [string[]] would join with a space.
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$Passthru
)

# A caller's profile must not change how this script runs.
Set-StrictMode -Off

# Bare words after binding, nested arrays flattened (see $Passthru).
$PassWords = @()
foreach ($p in @($Passthru)) { foreach ($q in @($p)) { if ($null -ne $q) { $PassWords += [string]$q } } }

# ---- PowerShell 7.3+ --------------------------------------------------------
# 7.3 brought standard argument passing to native programs (quotes and trailing
# backslashes reach docker/wsl intact); older versions also turn git's stderr
# into errors. Windows PowerShell 5.1 re-launches the script in pwsh. $args is
# always empty in a script with a param() block, so the child's command line is
# rebuilt from the bound parameters, protected against 5.1's legacy quoting:
# it drops embedded double quotes and lets a trailing backslash in a quoted
# value swallow the rest of the line. Only Windows PowerShell re-launches, and
# only once: a pwsh 6.x found on PATH would otherwise start itself for ever.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    if ($env:DRONEOS_RELAUNCHED) {
        Write-Host "ERROR: the re-launch started Windows PowerShell again. Install PowerShell 7.3+:  winget install Microsoft.PowerShell" -ForegroundColor Red
        exit 1
    }
    $pwshExe = $null
    foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe",
                     (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
                     "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe")) {
        if ($c -and (Test-Path -LiteralPath $c)) { $pwshExe = $c; break }
    }
    if (-not $pwshExe) {
        Write-Host "ERROR: build.ps1 needs PowerShell 7.3 or newer. Install it:  winget install Microsoft.PowerShell" -ForegroundColor Red
        exit 1
    }
    function Protect-LegacyArg([string]$Value) {
        if ($Value.Contains('"')) {
            Write-Host "ERROR: Windows PowerShell cannot pass on a value that contains a double quote: $Value`nRun build.ps1 with pwsh 7.3+ directly." -ForegroundColor Red
            exit 1
        }
        if ($Value -eq '') { return '""' }
        if ($Value -match '\s') { return ($Value -replace '(\\+)$', '$1$1') }
        return $Value
    }
    $fwd = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Key -eq 'Passthru') { continue }
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $fwd += "-$($kv.Key)" }
        } elseif ($kv.Value -is [array]) {
            $fwd += "-$($kv.Key)"; $fwd += Protect-LegacyArg ($kv.Value -join ',')
        } else {
            $fwd += "-$($kv.Key)"; $fwd += Protect-LegacyArg ([string]$kv.Value)
        }
    }
    foreach ($w in $PassWords) { $fwd += Protect-LegacyArg $w }
    Write-Host "Re-launching under PowerShell 7 ($pwshExe)..." -ForegroundColor Cyan
    $env:DRONEOS_RELAUNCHED = '1'
    try {
        & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    } catch {
        Write-Host "ERROR: cannot start ${pwshExe}: $_" -ForegroundColor Red
        exit 1
    }
    if ($null -eq $LASTEXITCODE) { exit 1 }
    exit $LASTEXITCODE
}
$psv = $PSVersionTable.PSVersion
if ($psv.Major -lt 7 -or ($psv.Major -eq 7 -and $psv.Minor -lt 3)) {
    Write-Host "ERROR: build.ps1 needs PowerShell 7.3 or newer (this is $psv). Update:  winget install Microsoft.PowerShell" -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = 'Stop'
# Probes such as 'docker info' are expected to fail; they must not throw.
# And quotes / empty arguments must reach docker and wsl.exe intact. Both
# whatever the caller's preferences are.
$PSNativeCommandUseErrorActionPreference = $false
$PSNativeCommandArgumentPassing = 'Standard'

if ($Help) {
    Get-Help -Detailed $PSCommandPath
    return
}

# ---- Arguments: validated before anything has a side effect ----------------- #
# Only KEY=VALUE overrides and --no-fix-perms may pass through to build.sh;
# anything else is a typo, or a build.sh flag that build.ps1 spells differently
# (--dry-run is -DryRun) - and must not be silently ignored next to -Purge.
$overrides = [System.Collections.Generic.List[string]]::new()
$NoFixPerms = $false
# KEY=VALUE lists, from -Set or bare words alike: from a PowerShell prompt
# "a=1,b=2" arrives as two elements, through "pwsh -File" (cmd, Task Scheduler,
# the 5.1 re-launch) as one string - so split on commas that start another KEY=.
function Add-Overrides([string]$Text, [string]$Origin) {
    foreach ($kv in ($Text -split ',\s*(?=[A-Za-z_][A-Za-z0-9_]*=)')) {
        $kv = $kv.Trim()
        if (-not $kv) { continue }
        if ($kv -notmatch '^[A-Za-z_][A-Za-z0-9_]*=') {
            throw "$Origin expects KEY=VALUE (e.g. IGconf_device_hostname=drone7), got '$kv'"
        }
        if ($kv.EndsWith(',')) {
            throw "${Origin}: '$kv' ends with a comma (an unquoted list split by cmd?). Quote the whole list: -Set 'A=1, B=2'"
        }
        $overrides.Add($kv)
    }
}
foreach ($w in $PassWords) {
    if ([string]::IsNullOrEmpty($w)) { continue }
    if ($w -ceq '--no-fix-perms') { $NoFixPerms = $true; continue }
    if ($w -match '^[A-Za-z_][A-Za-z0-9_]*=') { Add-Overrides $w 'A bare KEY=VALUE word'; continue }
    throw "Unknown argument '$w'. build.ps1 takes -Name parameters (see -Help; --dry-run is -DryRun, --purge is -Purge). Only KEY=VALUE overrides and --no-fix-perms are passed on to build.sh."
}
foreach ($item in @($Set)) { Add-Overrides $item '-Set' }
if ($FsOnly -and $ImageOnly) { throw "-FsOnly and -ImageOnly exclude each other (together they would build nothing)." }
$bound = $PSBoundParameters   # inside a script block $PSBoundParameters is that block's own
$actions = @('Purge', 'Clean', 'Deps', 'Shell') | Where-Object { $bound.ContainsKey($_) -and $bound[$_] }
if (@($actions).Count -gt 1) { throw ("-" + ($actions -join ', -') + " exclude each other.") }
if ($Wsl -and $Shell)     { throw "-Shell is a Docker option; for WSL just run:  wsl.exe -d <distro>" }
if ($Wsl -and $Rebuild)   { throw "-Rebuild is a Docker option; with -Wsl use -Deps to refresh the host packages" }
if ($Distro -and -not $Wsl) { throw "-Distro only applies together with -Wsl" }

$haveTty = -not ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)
if ($Interactive -and -not $haveTty) { throw "-Interactive needs an interactive terminal" }
if ($Shell -and -not $haveTty)       { throw "-Shell needs an interactive terminal" }

# Builds that end with an image: they get an out folder, a visibility probe
# and a result file.
$ExpectImage = -not ($FsOnly -or $Clean -or $Purge -or $Shell -or $Deps)

# ---- Paths ------------------------------------------------------------------ #
# The real case of an existing path (each component looked up in its parent;
# Get-Item and GetFullPath keep whatever case was typed). Linux is
# case-sensitive: /src/DRONEOS.yaml does not exist when droneos.yaml does.
function Get-CanonicalPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) { return $full }   # UNC: \\wsl.localhost is case-sensitive anyway
    $root = [System.IO.Path]::GetPathRoot($full)
    $cur = $root.ToUpperInvariant()
    foreach ($part in $full.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $entries = @()
        try { $entries = @([System.IO.Directory]::GetFileSystemEntries($cur, $part)) } catch { }
        $hit = $entries | Where-Object { [System.IO.Path]::GetFileName($_) -ceq $part } | Select-Object -First 1
        if (-not $hit) { $hit = $entries | Select-Object -First 1 }
        $cur = if ($hit) { $hit } else { Join-Path $cur $part }
    }
    return $cur
}
# A plain relative path is taken from $Base when one is given; '~', PSDrives
# (Temp:\x) and paths relative to the current location resolve the way cmdlets
# resolve them.
function Resolve-UserPath([string]$Path, [string]$Base) {
    if ($Base -and -not ([System.IO.Path]::IsPathRooted($Path) -or $Path -match '^~' -or $Path -match '^[^\\/]+:')) {
        $Path = Join-Path $Base $Path
    }
    $p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    return [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($p))
}
function Get-WslDistroOfPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -match '^\\\\(?:wsl\.localhost|wsl\$)\\([^\\]+)') { return $Matches[1] }
    return $null
}
# Windows -> WSL path, for the dry-run display only; real runs ask wslpath
# inside the distro (it knows the automount root and refuses unmounted drives).
function ConvertTo-WslPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -match '^\\\\(?:wsl\.localhost|wsl\$)\\[^\\]+(\\.*)?$') {
        return $(if ($Matches[1]) { $Matches[1] -replace '\\', '/' } else { '/' })
    }
    if ($full.StartsWith('\\')) { return $full }
    return '/mnt/' + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
}

$Root = Get-CanonicalPath $PSScriptRoot
foreach ($f in @('build.sh', 'droneos.yaml', 'docker\Dockerfile', 'docker\entrypoint.sh')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $f))) {
        throw "$f not found next to build.ps1 ($Root) - is this the droneos checkout?"
    }
}
# A checkout inside a WSL distro is built in that distro, with Linux git.
$RootDistro = Get-WslDistroOfPath $Root
if ($RootDistro) {
    if (-not $Wsl) { throw "This checkout lives inside the WSL distro '$RootDistro'. Build it with -Wsl, or run ./build.sh --docker inside the distro." }
    if ($Distro -and $Distro -ne $RootDistro) { throw "The checkout lives in the WSL distro '$RootDistro', not in '$Distro'." }
    $Distro = $RootDistro
}

$cfgPath = Get-CanonicalPath (Resolve-UserPath $Config $Root)
if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) { throw "Config not found: $cfgPath" }
$outPath = if ($Out) { Resolve-UserPath $Out $null } else { Join-Path $Root 'out' }

# ---- git: version and submodule --------------------------------------------- #
function Find-Git {
    $g = (Get-Command git -ErrorAction SilentlyContinue).Source
    if ($g) { return $g }
    foreach ($c in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
                     "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}
$Git = Find-Git

# Version tag for rpi-image-gen's chroot-/deploy-<version> directories. Taken
# here for a checkout on a Windows drive (Windows git owns its index). For a
# checkout inside a distro, and whenever git fails, nothing is passed and
# build.sh runs git describe itself.
$Version = $null
if (-not $RootDistro) {
    if ($Git) { $Version = & $Git -c safe.directory=* -C $Root describe --tags --always --dirty 2>$null | Select-Object -First 1 }
    if (-not $Version) { Write-Warning "git describe failed (is git installed?) - build.sh names the build itself." }
}

# rpi-image-gen submodule. The container mounts /src read-only, so Docker builds
# fetch it here. A checkout inside a distro is left to build.sh: Windows git
# would check its scripts out with CRLF line endings.
if (-not $RootDistro -and -not (Test-Path -LiteralPath (Join-Path $Root 'rpi-image-gen\rpi-image-gen'))) {
    if ($DryRun) {
        Write-Host "(dry run: the rpi-image-gen submodule is not checked out; a real run fetches it first)" -ForegroundColor Yellow
    } elseif (-not $Git) {
        throw "rpi-image-gen submodule is missing and git was not found. Run: git submodule update --init --recursive"
    } else {
        Write-Host "Fetching the rpi-image-gen submodule..." -ForegroundColor Cyan
        & $Git -C $Root submodule update --init --recursive rpi-image-gen
        if ($LASTEXITCODE -or -not (Test-Path -LiteralPath (Join-Path $Root 'rpi-image-gen\rpi-image-gen'))) {
            throw "git submodule update failed"
        }
    }
}

# ---- build.sh arguments shared by both back ends ----------------------------- #
$shArgs = [System.Collections.Generic.List[string]]::new()
if ($FsOnly)      { $shArgs.Add('--fs-only') }
if ($ImageOnly)   { $shArgs.Add('--image-only') }
if ($Interactive) { $shArgs.Add('--interactive') }
if ($Clean)       { $shArgs.Add('--clean') }
if ($NoAptCache)  { $shArgs.Add('--no-apt-cache') }
if ($NoFixPerms)  { $shArgs.Add('--no-fix-perms') }
if ($overrides.Count) { $shArgs.Add('--'); $overrides | ForEach-Object { $shArgs.Add($_) } }

# build.sh lists the images it copied in this file of the out folder, so the
# summary shows this run's images, not whatever else lies there.
$ResultName = '.droneos-result-' + [guid]::NewGuid().ToString('N')

function Show-Result {
    $file = Join-Path $outPath $ResultName
    $names = @()
    if (Test-Path -LiteralPath $file) {
        $names = @(Get-Content -LiteralPath $file | Where-Object { $_ })
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    if (-not $names) {
        Write-Host "The build finished, but it reported no image." -ForegroundColor Red
        return $false
    }
    Write-Host ""
    Write-Host "Built:" -ForegroundColor Green
    foreach ($n in $names) {
        $i = Get-Item -LiteralPath (Join-Path $outPath $n) -ErrorAction SilentlyContinue
        if ($i) { Write-Host ("  {0,8:N0} MB  {1}" -f ($i.Length / 1MB), $i.FullName) } else { Write-Host "  $n" }
    }
    Write-Host "Flash with Raspberry Pi Imager -> 'Use custom'." -ForegroundColor Green
    return $true
}

# A file Linux must find in the out folder: proves that Docker / WSL write into
# this very folder (a mapped network drive or a subst drive is not visible to
# them), before minutes of building rather than after.
function New-OutProbe {
    New-Item -ItemType Directory -Force -Path $outPath | Out-Null
    $name = '.droneos-probe-' + [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText((Join-Path $outPath $name), '')
    return $name
}
function Remove-OutProbe([string]$Name) {
    if ($Name) { Remove-Item -LiteralPath (Join-Path $outPath $Name) -Force -ErrorAction SilentlyContinue }
}
# Captured native output is decoded with the console's encoding; without a
# console (scheduled task) setting it throws, and the default is then kept.
function Set-ConsoleEncoding($Encoding) {
    try { [Console]::OutputEncoding = $Encoding } catch { }
}

# =========================================================================== #
#                                   WSL                                        #
# =========================================================================== #
if ($Wsl) {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe not found. Install WSL (wsl --install -d Debian) or drop -Wsl to use Docker Desktop."
    }

    $tail = [System.Collections.Generic.List[string]]::new()
    if ($Deps)  { $tail.Add('--deps') }
    if ($Purge) { $tail.Add('--purge') }
    $shArgs | ForEach-Object { $tail.Add($_) }

    if ($DryRun) {
        # Nothing is started: the paths are mapped here, not by wslpath.
        $d = if ($Distro) { "-d $Distro " } else { '' }
        $o = if ($ExpectImage) { " -o $(ConvertTo-WslPath $outPath)" } else { '' }
        Write-Host "DRY RUN - would execute (DRONEOS_ROOT=$(ConvertTo-WslPath $Root)$(if ($Version) { " DRONEOS_VERSION=$Version" }) via WSLENV):" -ForegroundColor Yellow
        Write-Host "  wsl.exe ${d}-e bash <CRLF-free copy of build.sh in %TEMP%> -c $(ConvertTo-WslPath $cfgPath)$o $($tail -join ' ')"
        return
    }

    # The distro must be Debian-like and must see the checkout, the config, the
    # temp script and the out folder. wslpath does the Windows -> Linux mapping
    # and fails for drives the distro has not mounted.
    $preflight = @'
printf 'distro=%s\n' "$WSL_DISTRO_NAME"
if ! command -v bash >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then exit 10; fi
r=$(wslpath -a -u "$1" 2>/dev/null) && [ -f "$r/build.sh" ] || exit 11
c=$(wslpath -a -u "$2" 2>/dev/null) && [ -f "$c" ] || exit 12
s=$(wslpath -a -u "$3" 2>/dev/null) && [ -f "$s" ] || exit 14
o=
if [ -n "$4" ]; then o=$(wslpath -a -u "$4" 2>/dev/null) && [ -f "$o/$5" ] || exit 13; fi
printf 'root=%s\ncfg=%s\nscript=%s\nout=%s\n' "$r" "$c" "$s" "$o"
'@

    # build.sh must be LF inside Linux; a Windows checkout may have CRLF, so run
    # a normalised copy from %TEMP% and tell it where the real checkout is. One
    # file per run (parallel runs must not overwrite each other's), deleted after.
    $tmpScript = Join-Path ([System.IO.Path]::GetTempPath()) ("droneos-build-{0}-{1}.sh" -f $PID, [System.IO.Path]::GetRandomFileName().Replace('.', ''))
    $probe = $null
    $prevWslEnv = $env:WSLENV
    $prevUtf8 = $env:WSL_UTF8
    $prevEnc = [Console]::OutputEncoding
    $fwdKeys = @('DRONEOS_ROOT', 'DRONEOS_VERSION', 'SOURCE_DATE_EPOCH', 'DRONEOS_RESULT')
    $prevVals = @{}
    foreach ($k in $fwdKeys) { $prevVals[$k] = [Environment]::GetEnvironmentVariable($k) }
    $code = 1
    try {
        $content = [System.IO.File]::ReadAllText((Join-Path $Root 'build.sh'))
        [System.IO.File]::WriteAllText($tmpScript, $content.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
        if ($ExpectImage) { $probe = New-OutProbe }

        $pa = [System.Collections.Generic.List[string]]::new()
        if ($Distro) { $pa.Add('-d'); $pa.Add($Distro) }
        foreach ($x in @('-e', 'sh', '-c', $preflight, 'droneos-preflight', $Root, $cfgPath, $tmpScript,
                         $(if ($ExpectImage) { $outPath } else { '' }), $(if ($probe) { $probe } else { '' }))) { $pa.Add($x) }
        $env:WSL_UTF8 = '1'                                              # wsl.exe's own messages
        Set-ConsoleEncoding ([System.Text.UTF8Encoding]::new($false))    # the distro's output
        $pre = @(& wsl.exe @pa 2>&1 | ForEach-Object { "$_" })
        $preCode = $LASTEXITCODE
        Set-ConsoleEncoding $prevEnc
        Remove-OutProbe $probe; $probe = $null

        $info = @{}
        foreach ($line in $pre) { if ($line -match '^(distro|root|cfg|script|out)=(.*)$') { $info[$Matches[1]] = $Matches[2] } }
        $dn = if ($info['distro']) { $info['distro'] } elseif ($Distro) { $Distro } else { 'default' }
        switch ($preCode) {
            0  { }
            10 { throw "The WSL distro '$dn' has no bash or dpkg - it must be Debian or Ubuntu. Pass -Distro <name> (wsl -l -v lists them), or drop -Wsl to build in Docker Desktop." }
            11 { throw "WSL ($dn) cannot see the checkout $Root. Mapped network drives and subst drives are not mounted in WSL - use a checkout on a local drive." }
            12 { throw "WSL ($dn) cannot see the config $cfgPath (mapped network or subst drive?)." }
            13 { throw "WSL ($dn) cannot see the out folder $outPath. Mapped network drives and subst drives are not mounted in WSL - use -Out on a local drive." }
            14 { throw "WSL ($dn) cannot see the temporary script $tmpScript (is TEMP on a network drive?)." }
            default { throw "wsl.exe failed (exit $preCode):`n$($pre -join "`n")" }
        }

        $wslArgs = [System.Collections.Generic.List[string]]::new()
        $wslArgs.Add('-d'); $wslArgs.Add($info['distro'])
        $wslArgs.Add('-e'); $wslArgs.Add('bash'); $wslArgs.Add($info['script'])
        $wslArgs.Add('-c'); $wslArgs.Add($info['cfg'])
        if ($ExpectImage) { $wslArgs.Add('-o'); $wslArgs.Add($info['out']) }
        $tail | ForEach-Object { $wslArgs.Add($_) }

        # Environment handed over through WSLENV: the checkout's Linux path and,
        # when known, the version, SOURCE_DATE_EPOCH and the result file name.
        $fwd = [ordered]@{ DRONEOS_ROOT = $info['root'] }
        if ($Version)               { $fwd['DRONEOS_VERSION'] = $Version }
        if ($env:SOURCE_DATE_EPOCH) { $fwd['SOURCE_DATE_EPOCH'] = $env:SOURCE_DATE_EPOCH }
        if ($ExpectImage)           { $fwd['DRONEOS_RESULT'] = $ResultName }
        foreach ($k in $fwd.Keys) { [Environment]::SetEnvironmentVariable($k, $fwd[$k]) }
        $parts = @()
        if ($env:WSLENV) { $parts = $env:WSLENV -split ':' | Where-Object { $_ -and ($_ -notin $fwdKeys) } }
        $env:WSLENV = (@($parts) + @($fwd.Keys)) -join ':'

        Write-Host "Building in WSL ($($info['distro']))..." -ForegroundColor Cyan
        & wsl.exe @wslArgs
        $code = $LASTEXITCODE
    }
    finally {
        Set-ConsoleEncoding $prevEnc
        $env:WSLENV = $prevWslEnv
        $env:WSL_UTF8 = $prevUtf8
        foreach ($k in $fwdKeys) { [Environment]::SetEnvironmentVariable($k, $prevVals[$k]) }
        Remove-OutProbe $probe
        Remove-Item -LiteralPath $tmpScript -Force -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) {
        Write-Host "Build failed (exit $code)." -ForegroundColor Red
        exit $code
    }
    if ($ExpectImage -and -not (Show-Result)) { exit 1 }
    exit 0
}

# =========================================================================== #
#                               Docker Desktop                                 #
# =========================================================================== #
$ImageTag   = if ($env:DRONEOS_BUILDER_IMAGE) { $env:DRONEOS_BUILDER_IMAGE } else { 'droneos-builder:trixie' }
$WorkVolume = if ($env:DRONEOS_WORK_VOLUME)   { $env:DRONEOS_WORK_VOLUME }   else { 'droneos-work' }

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker not found on PATH. Install Docker Desktop (winget install Docker.DockerDesktop) or use -Wsl."
}

# --mount rather than -v: a source Docker Desktop cannot see (mapped network
# drive, subst drive) fails at once instead of turning into an empty folder.
# The value is CSV, so the source is quoted (a path may contain a comma).
function New-BindMount([string]$Source, [string]$Target, [switch]$ReadOnly) {
    $spec = "type=bind,`"source=$Source`",target=$Target"
    if ($ReadOnly) { $spec += ',readonly' }
    return @('--mount', $spec)
}
$mounts = @() + (New-BindMount $Root '/src' -ReadOnly) + @('--mount', "type=volume,source=$WorkVolume,target=/work")
$withOut = $ExpectImage -or $Shell
if ($withOut) { $mounts += New-BindMount $outPath '/out' }
# Config path as the container sees it (/src is the checkout; anything outside
# gets its own read-only mount at /cfg).
$rootPrefix = $Root.TrimEnd('\') + '\'
if ($cfgPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    $cfgRel = $cfgPath.Substring($rootPrefix.Length) -replace '\\', '/'
    $cfgInside = "/src/$cfgRel"
    $cfgId = $cfgRel
} else {
    $mounts += New-BindMount (Split-Path -Parent $cfgPath) '/cfg' -ReadOnly
    $cfgInside = '/cfg/' + (Split-Path -Leaf $cfgPath)
    $cfgId = $cfgPath   # inside the container every outside config is /cfg/<name>
}

$inner = [System.Collections.Generic.List[string]]::new()
$inner.Add('--in-container'); $inner.Add('-B'); $inner.Add('/work')
if ($withOut) { $inner.Add('-o'); $inner.Add('/out') }
$inner.Add('-c'); $inner.Add($cfgInside)
$shArgs | ForEach-Object { $inner.Add($_) }

$envs = @('-e', 'DRONEOS_IN_CONTAINER=1', '-e', 'DRONEOS_ROOT=/src', '-e', 'TERM=xterm-256color', '-e', "DRONEOS_CONFIG_ID=$cfgId")
if ($Version)               { $envs += @('-e', "DRONEOS_VERSION=$Version") }
if ($env:SOURCE_DATE_EPOCH) { $envs += @('-e', "SOURCE_DATE_EPOCH=$($env:SOURCE_DATE_EPOCH)") }
if ($ExpectImage)           { $envs += @('-e', "DRONEOS_RESULT=$ResultName") }

# Named, so an interrupted client can remove the container afterwards.
$ContainerName = "droneos-build-$PID-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$runArgs = @('run', '--rm', '-i')
if ($haveTty) { $runArgs += '-t' }
$runArgs += @('--name', $ContainerName, '--privileged', '--hostname', 'droneos-builder') + $envs + $mounts

$bargs = @('build', '-t', $ImageTag)
if ($Rebuild)  { $bargs += @('--pull', '--no-cache') }
elseif ($Deps) { $bargs += '--pull' }
$bargs += (Join-Path $Root 'docker')

if ($DryRun) {
    Write-Host "DRY RUN - would execute:" -ForegroundColor Yellow
    if ($Purge) { Write-Host "  docker volume rm -f $WorkVolume"; return }
    Write-Host "  docker $($bargs -join ' ')"
    if ($Deps)  { return }
    if ($Shell) { Write-Host "  docker run --rm -it --privileged $($envs -join ' ') $($mounts -join ' ') --entrypoint bash $ImageTag"; return }
    Write-Host "  docker $($runArgs -join ' ') $ImageTag $($inner -join ' ')"
    return
}

# ---- The engine ---------------------------------------------------------------
function Get-DockerState {
    $o = @(& docker info --format '{{.OSType}}' 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -eq 0) { return [pscustomobject]@{ Ready = $true; OSType = ($o | Select-Object -Last 1).Trim(); Error = '' } }
    return [pscustomobject]@{ Ready = $false; OSType = ''; Error = ($o -join "`n").Trim() }
}
function Find-DockerDesktop {
    foreach ($c in @("$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
                     "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe")) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}
$st = Get-DockerState
if (-not $st.Ready) {
    if ($st.Error -match '(?i)access is denied|permission denied') {
        throw "docker cannot talk to its engine:`n$($st.Error)`nAdd your account to the 'docker-users' group, then sign out and in again."
    }
    if ($st.Error -match '(?i)paused') { throw "Docker Desktop is paused - resume it and run again.`n$($st.Error)" }
    if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        $dd = Find-DockerDesktop
        if (-not $dd) { throw "The docker engine is not reachable and Docker Desktop is not installed:`n$($st.Error)`nStart your Docker engine, or use -Wsl." }
        Write-Host "Docker Desktop is not running - starting it..." -ForegroundColor Yellow
        Start-Process -FilePath $dd | Out-Null
    } else {
        Write-Host "Waiting for Docker Desktop's engine..." -ForegroundColor Yellow
    }
    $deadline = (Get-Date).AddSeconds(180)
    do {
        Start-Sleep -Seconds 5
        $st = Get-DockerState
    } until ($st.Ready -or (Get-Date) -gt $deadline)
    if (-not $st.Ready) { throw "Docker's engine did not come up within 3 minutes. Last answer of 'docker info':`n$($st.Error)" }
}
# The builder is a Linux image; in Windows-containers mode 'docker build'
# fails with a confusing error.
if ($st.OSType -and $st.OSType -ne 'linux') {
    throw "Docker is in $($st.OSType)-containers mode. Switch Docker Desktop to Linux containers (tray icon -> 'Switch to Linux containers...') and run again."
}

if ($Purge) {
    Write-Host "Removing work volume $WorkVolume..." -ForegroundColor Yellow
    & docker volume rm -f $WorkVolume | Out-Null
    if ($LASTEXITCODE) { throw "docker volume rm failed ($LASTEXITCODE) - is a build still running?" }
    Write-Host "Done." -ForegroundColor Green
    return
}

# Builder image (cached; -Rebuild forces a clean rebuild, -Deps re-pulls the base).
Write-Host "Builder image $ImageTag..." -ForegroundColor Cyan
& docker @bargs
if ($LASTEXITCODE) { throw "docker build failed ($LASTEXITCODE)" }
if ($Deps) {
    Write-Host "Dependencies live in the builder image; it is up to date." -ForegroundColor Green
    return
}

# The engine must see the checkout, the config and this very out folder.
$probe = $null
try {
    if ($withOut) { $probe = New-OutProbe }
    $check = 'test -f /src/build.sh || exit 11; test -f "$1" || exit 12; if [ -n "$2" ]; then test -f "/out/$2" || exit 13; fi'
    $pre = @(& docker run --rm --entrypoint sh @mounts $ImageTag -c $check droneos-preflight $cfgInside $(if ($probe) { $probe } else { '' }) 2>&1 | ForEach-Object { "$_" })
    $preCode = $LASTEXITCODE
}
finally { Remove-OutProbe $probe }
switch ($preCode) {
    0   { }
    11  { throw "Docker Desktop cannot see the checkout $Root (mapped network or subst drive?). Use a checkout on a local drive." }
    12  { throw "Docker Desktop cannot see the config $cfgPath (mapped network or subst drive?)." }
    13  { throw "Docker Desktop writes /out somewhere other than $outPath (mapped network or subst drive?). Use -Out on a local drive." }
    125 { throw "Docker Desktop cannot mount a folder - mapped network drives and subst drives are not visible to it. Use folders on a local drive.`n$($pre -join "`n")" }
    default { throw "The pre-flight container failed (exit $preCode):`n$($pre -join "`n")" }
}

# arm64 binfmt handler in the Docker VM kernel. Docker Desktop's VM registers
# one ('aarch64') when it starts; other engines may not, and then
# tonistiigi/binfmt installs qemu-aarch64 with the F flag (so it also works
# inside the chroot). The probe recognises a handler by its content, not its
# name. -Clean needs no emulation.
$arch = (& docker info --format '{{.Architecture}}' 2>$null | Select-Object -First 1)
if (-not $Clean -and $arch -notmatch '^(aarch64|arm64)') {
    & docker run --rm --privileged $ImageTag --binfmt-check *> $null
    if ($LASTEXITCODE) {
        Write-Host "Registering the arm64 QEMU binfmt handler in the Docker VM (tonistiigi/binfmt)..." -ForegroundColor Cyan
        & docker run --rm --privileged tonistiigi/binfmt --install arm64
        if ($LASTEXITCODE) { throw "binfmt registration failed ($LASTEXITCODE)" }
    }
}

if ($Shell) {
    & docker run --rm -it --privileged --hostname droneos-builder @envs @mounts --entrypoint bash $ImageTag
    exit $LASTEXITCODE
}

Write-Host "Building in Docker ($ImageTag, work volume $WorkVolume)..." -ForegroundColor Cyan
$code = 1
try {
    & docker @runArgs $ImageTag @inner
    $code = $LASTEXITCODE
}
finally {
    # --rm has normally removed it; this covers an interrupted client.
    & docker container inspect $ContainerName *> $null
    if ($LASTEXITCODE -eq 0) { & docker rm -f $ContainerName *> $null }
}
if ($code -ne 0) {
    Write-Host "Build failed (exit $code)." -ForegroundColor Red
    exit $code
}
if ($ExpectImage -and -not (Show-Result)) { exit 1 }
exit 0
