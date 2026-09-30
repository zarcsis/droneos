#!/bin/bash
#
# build.sh - build the DroneOS Raspberry Pi image (Linux entry point).
#
# The image is described by droneos.yaml and produced by the rpi-image-gen
# submodule (Raspberry Pi's image generator: mmdebstrap + bdebstrap + genimage).
# rpi-image-gen runs on Linux only: it needs a Debian-based host with mount and
# user namespaces, plus an arm64 binfmt handler (QEMU) when the host is not arm64.
#
# Two ways to run this script:
#
#   ./build.sh            native build on Debian / Ubuntu / Raspberry Pi OS. On
#                         the first run the host packages are installed with
#                         sudo (rpi-image-gen/install_deps.sh + QEMU user mode).
#
#   ./build.sh --docker   hermetic build inside the droneos-builder container
#                         (docker/Dockerfile: Debian trixie + every dependency).
#                         Works on any Linux that has docker or podman; the arm64
#                         binfmt handler is registered in the host kernel with
#                         tonistiigi/binfmt when it is missing.
#
# build.ps1 is the Windows front end: it runs this script in Docker Desktop
# (default) or inside a WSL distro (-Wsl).
#
# Result: out/<image name>.img - flash it with Raspberry Pi Imager ("Use custom")
# or   sudo rpi-imager --cli out/<image name>.img /dev/mmcblk0
# rpi-image-gen's own deploy set (zstd-compressed image, IDP archive, SBOM,
# manifest) stays under <work dir>/deploy-<version>/.
#
# Sources that sit on a Windows filesystem (WSL /mnt/c, a Docker Desktop bind
# mount) are staged into a Linux directory first: mmdebstrap cannot build a
# rootfs on drvfs/9p (ownership, device nodes, mounts), and a Windows checkout
# of the submodule carries CRLF in its extension-less scripts (rpi-image-gen,
# bin/ns, bin/ig, depends). The staged copy is refreshed on every run.

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
if [[ ! -t 1 ]]; then RED=''; GREEN=''; YELLOW=''; NC=''; fi

log()  { echo "${GREEN}==>${NC} $*"; }
info() { echo "    $*"; }
warn() { echo "${YELLOW}WARNING:${NC} $*" >&2; }
die()  { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }

# Where the checkout is. build.ps1 and the container entry point run a
# CRLF-normalised copy of this file from /tmp and tell us the real root.
ROOT=${DRONEOS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}
IMAGE_TAG=${DRONEOS_BUILDER_IMAGE:-droneos-builder:trixie}
WORK_VOLUME=${DRONEOS_WORK_VOLUME:-droneos-work}

usage() {
    cat <<'USAGE'
Usage: ./build.sh [options] [IGconf_key=value ...]

Builds the DroneOS image described by droneos.yaml with rpi-image-gen.

Options:
  -c, --config <file>    Config to build (default: droneos.yaml)
  -B, --build-dir <dir>  rpi-image-gen work root (default: ./work, or
                         ~/.cache/droneos/work when the sources sit on a
                         Windows filesystem). Must be a Linux filesystem.
  -o, --out <dir>        Where the finished .img is copied (default: ./out)
      --docker           Build inside the droneos-builder container instead of
                         on this host (needs docker or podman)
      --engine <name>    Container engine for --docker: docker (default), podman
      --rebuild          --docker: rebuild the builder image from scratch
      --shell            --docker: open a shell in the builder container
      --deps             Install / upgrade the host dependencies (sudo) and
                         exit; with --docker: refresh the builder image and exit
  -f, --fs-only          Build the filesystem only, skip image generation
  -i, --image-only       Skip the filesystem, only (re)generate the image
  -I, --interactive      Let rpi-image-gen ask before each stage
      --clean            Remove the rootfs, image and deploy dirs of this config
      --purge            Delete the whole work tree (--docker: the work volume)
      --no-apt-cache     Do not keep downloaded .debs between builds
      --no-fix-perms     Never chmod o+x the work dir's parents (see notes)
      --dry-run          Print what would run and exit
  -h, --help             This help

  key=value words (anywhere, or after --) are passed to rpi-image-gen as
  variable overrides, e.g.   ./build.sh IGconf_device_user1pass='Fo0bar!!'

Notes:
  * apt inside the chroot runs as its own user and needs world-execute on every
    parent of the work dir. A Debian home directory is 0700 by default, so the
    script adds o+x to the parents it owns (what upstream CI does as well);
    --no-fix-perms turns that into a warning.
  * Downloaded .debs are kept in <work dir>/apt-cache and bind-mounted into the
    chroot, so a rebuild does not fetch Debian again (--no-apt-cache disables).
USAGE
}

# ---- Arguments --------------------------------------------------------------
CONFIG=''
WORKROOT=''
OUTDIR=''
MODE=native
ENGINE=''
IN_CONTAINER=${DRONEOS_IN_CONTAINER:-0}
DEPS=0; FS_ONLY=0; IMAGE_ONLY=0; INTERACTIVE=0; CLEAN=0; PURGE=0
REBUILD=0; SHELL_MODE=0; APT_CACHE=1; FIX_PERMS=1; DRY_RUN=0
OVERRIDES=()

need_arg() { [[ $# -ge 2 && -n $2 ]] || die "$1 needs a value"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)        need_arg "$@"; CONFIG=$2; shift 2 ;;
        --config=*)         CONFIG=${1#*=}; shift ;;
        -B|--build-dir)     need_arg "$@"; WORKROOT=$2; shift 2 ;;
        --build-dir=*)      WORKROOT=${1#*=}; shift ;;
        -o|--out)           need_arg "$@"; OUTDIR=$2; shift 2 ;;
        --out=*)            OUTDIR=${1#*=}; shift ;;
        --docker)           MODE=docker; shift ;;
        --engine)           need_arg "$@"; ENGINE=$2; shift 2 ;;
        --engine=*)         ENGINE=${1#*=}; shift ;;
        --rebuild)          REBUILD=1; shift ;;
        --shell)            SHELL_MODE=1; shift ;;
        --deps)             DEPS=1; shift ;;
        -f|--fs-only)       FS_ONLY=1; shift ;;
        -i|--image-only)    IMAGE_ONLY=1; shift ;;
        -I|--interactive)   INTERACTIVE=1; shift ;;
        --clean)            CLEAN=1; shift ;;
        --purge)            PURGE=1; shift ;;
        --no-apt-cache)     APT_CACHE=0; shift ;;
        --no-fix-perms)     FIX_PERMS=0; shift ;;
        --in-container)     IN_CONTAINER=1; shift ;;
        --dry-run)          DRY_RUN=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        --)                 shift; OVERRIDES+=("$@"); break ;;
        [A-Za-z_]*=*)       OVERRIDES+=("$1"); shift ;;
        *)                  usage >&2; die "Unknown argument: $1" ;;
    esac
done

for kv in "${OVERRIDES[@]}"; do
    [[ $kv =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "Override must be key=value: '$kv'"
done

[[ -d $ROOT ]] || die "Checkout not found: $ROOT"
CONFIG=${CONFIG:-$ROOT/droneos.yaml}
[[ -f $CONFIG ]] || die "Config not found: $CONFIG"
CONFIG=$(realpath -e "$CONFIG")
OUTDIR=${OUTDIR:-$ROOT/out}

# Version tag for rpi-image-gen's chroot-/deploy-<version> directories. Computed
# on the host and handed down by build.ps1 / --docker, because inside the
# container the bind-mounted index always looks dirty. Restricted to characters
# that are safe in a path component (a tag like release/1.0 must not nest dirs).
VERSION=${DRONEOS_VERSION:-$(git -c safe.directory='*' -C "$ROOT" describe --tags --always --dirty 2>/dev/null || true)}
VERSION=${VERSION:-$(date +%Y-%m-%d)}
VERSION=${VERSION//[^A-Za-z0-9._-]/_}

# ---- Helpers ----------------------------------------------------------------
ensure_submodule() {
    [[ -f "$ROOT/rpi-image-gen/rpi-image-gen" ]] && return 0
    if [[ $IN_CONTAINER -eq 1 ]]; then
        die "rpi-image-gen submodule is not checked out. On the host run: git submodule update --init --recursive"
    fi
    [[ -e "$ROOT/.git" ]] || die "rpi-image-gen submodule missing and $ROOT is not a git checkout"
    command -v git >/dev/null 2>&1 || die "git is required to fetch the rpi-image-gen submodule"
    log "Fetching the rpi-image-gen submodule..."
    git -c safe.directory='*' -C "$ROOT" submodule update --init --recursive rpi-image-gen
    [[ -f "$ROOT/rpi-image-gen/rpi-image-gen" ]] || die "Submodule checkout failed"
}

# Filesystem type of a path (stat -f). Windows/network/FUSE mounts cannot host
# the build (no ownership, device nodes or bind mounts) and need staging.
fs_type() { stat -f -c %T "$1" 2>/dev/null || echo unknown; }
fs_is_foreign() {
    case $(fs_type "$1") in
        v9fs|9p|drvfs|fuse*|virtiofs|cifs|smb*|nfs*|vboxsf|prl_fs|ntfs*|vfat|msdos|exfat|fat|hfs*|afs|sshfs|autofs) return 0 ;;
        *) return 1 ;;
    esac
}

# May this file have its CRLF rewritten? Callers only pass files that grep -I
# already considers text (no NUL bytes); file(1) then vetoes the binary
# families that can be NUL-free, so keyrings, images and archives stay intact
# while unit files, INI-style configs and templates are treated as text.
is_text_file() {
    local f=$1 mime=''
    command -v file >/dev/null 2>&1 && mime=$(file -b --mime-type "$f" 2>/dev/null || true)
    case $mime in
        image/svg+xml) return 0 ;;   # XML, not pixels
        image/*|audio/*|video/*|font/*) return 1 ;;
        application/pgp*|application/x-bytecode*|application/zip|application/gzip|application/x-xz|\
        application/x-bzip2|application/zstd|application/x-tar|application/x-7z-compressed|\
        application/x-rar|application/x-executable|application/x-sharedlib|application/x-object|\
        application/x-pie-executable|application/x-dosexec|application/x-mach-binary|\
        application/vnd.*|application/pdf|application/x-sqlite3|application/wasm) return 1 ;;
    esac
    return 0
}

# Copy the checkout to a Linux directory, drop CRLF from text files, make sure
# the tool entry points are executable.
stage_sources() {
    local dst=$1
    log "Staging sources: $ROOT -> $dst"
    mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --chmod=go-w \
            --exclude '/.git' --exclude '/rpi-image-gen/.git' \
            --exclude '/work' --exclude '/out' --exclude '__pycache__' \
            "$ROOT/" "$dst/"
    else
        # rsync is one of the packages install_deps installs; until then copy.
        info "rsync not available - copying with cp"
        rm -rf -- "$dst"
        mkdir -p "$dst"
        (cd "$ROOT" && find . -mindepth 1 -maxdepth 1 \
            ! -name .git ! -name work ! -name out -exec cp -a {} "$dst/" \;)
        rm -rf -- "$dst/rpi-image-gen/.git"
        find "$dst" -name __pycache__ -type d -prune -exec rm -rf {} +
        chmod -R go-w "$dst"
    fi

    # grep -I skips binaries and is_text_file confirms the type, so keyrings and
    # images are never rewritten.
    local n=0 f
    while IFS= read -r -d '' f; do
        is_text_file "$f" || continue
        sed -i 's/\r$//' "$f"
        n=$((n + 1))
    done < <(grep -rIlZ $'\r' "$dst" 2>/dev/null || true)
    if [[ $n -gt 0 ]]; then info "normalised CRLF -> LF in $n text file(s)"; fi

    # A Windows filesystem reports every file as 0777 and a Linux checkout keeps
    # git's modes; either way the entry points must be executable.
    chmod +x "$dst/rpi-image-gen/rpi-image-gen" "$dst/rpi-image-gen/install_deps.sh"
    local d
    for d in bin scripts layer-hooks; do
        [[ -d "$dst/rpi-image-gen/$d" ]] && find "$dst/rpi-image-gen/$d" -type f -exec chmod +x {} +
    done
    find "$dst" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
    return 0
}

# rpi-image-gen's own checker. It exit()s instead of returning, hence the
# subshell. Prints the apt package list when something is missing.
deps_missing() {
    if ( source "$IG/lib/dependencies.sh" && dependencies_check --category all "$IG/depends" ) >/dev/null 2>&1; then
        return 1
    fi
    return 0
}
print_missing_deps() {
    ( source "$IG/lib/dependencies.sh" && dependencies_check --category all "$IG/depends" ) || true
}

host_is_arm64() {
    case $(uname -m) in aarch64|arm64) return 0 ;; *) return 1 ;; esac
}

install_deps() {
    local -a sudo=()
    if [[ $(id -u) -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || die "sudo is needed to install the host dependencies"
        sudo=(sudo)
    fi
    local -a extra=(file zstd git ca-certificates rsync)
    host_is_arm64 || extra+=(qemu-user-static binfmt-support arch-test)
    log "Installing host dependencies with apt..."
    "${sudo[@]}" apt-get update
    "${sudo[@]}" apt-get install -y --no-install-recommends "${extra[@]}"
    # install_deps.sh refuses to finish while binfmt_misc is not loaded, so load
    # it first (a no-op where it is built in, e.g. WSL2).
    if ! grep -q binfmt_misc /proc/filesystems 2>/dev/null; then
        "${sudo[@]}" modprobe binfmt_misc || warn "could not load binfmt_misc"
    fi
    "${sudo[@]}" "$IG/install_deps.sh" || die "rpi-image-gen/install_deps.sh failed"
    host_is_arm64 || "${sudo[@]}" update-binfmts --enable qemu-aarch64 >/dev/null 2>&1 || true
}

# Is the arm64 handler registered (and enabled) in this kernel? Mounting
# binfmt_misc inside a container only exposes what the host already has.
binfmt_arm64_present() {
    local h=/proc/sys/fs/binfmt_misc/qemu-aarch64
    if [[ ! -e $h && $(id -u) -eq 0 ]]; then
        mountpoint -q /proc/sys/fs/binfmt_misc 2>/dev/null \
            || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    fi
    [[ -e $h ]] && head -n1 "$h" | grep -q enabled
}

# The arm64 binfmt handler must be registered in the kernel (with the F flag
# so it works inside the chroot). On a native arm64 host nothing is needed.
check_binfmt() {
    host_is_arm64 && return 0
    binfmt_arm64_present && return 0
    if [[ $IN_CONTAINER -eq 1 ]]; then
        die "no arm64 binfmt handler in the host kernel. Register it once on the host:
         docker run --privileged --rm tonistiigi/binfmt --install arm64
       (build.sh --docker and build.ps1 do this automatically)"
    fi
    die "no arm64 binfmt handler (QEMU user emulation). Run ./build.sh --deps, or:
         sudo apt install qemu-user-static binfmt-support && sudo update-binfmts --enable qemu-aarch64"
}

# apt inside the chroot runs as _apt (a subuid on the host) and must traverse
# every parent of the work dir. Upstream CI does chmod o+x $HOME for this.
fix_parent_perms() {
    [[ $(id -u) -eq 0 ]] && return 0
    local p mode
    p=$(realpath -e "$1")
    while [[ $p != / ]]; do
        mode=$(stat -c %a "$p")
        if (( 8#$mode & 1 )); then
            p=$(dirname "$p"); continue
        fi
        if [[ $FIX_PERMS -eq 1 && -O $p ]]; then
            log "chmod o+x $p (apt inside the chroot must traverse it)"
            chmod o+x "$p"
        else
            warn "$p is mode $mode (no world-execute); apt inside the chroot will fail. Fix: chmod o+x '$p'"
        fi
        p=$(dirname "$p")
    done
    return 0
}

getvar() {
    local line
    line=$(grep -m1 "^$1=" "$2" 2>/dev/null) || return 1
    line=${line#*=}; line=${line#\"}; line=${line%\"}
    [[ -n $line ]] || return 1
    printf '%s\n' "$line"
}

purge_native() {
    if [[ ! -d $WORKROOT ]]; then info "nothing to purge ($WORKROOT does not exist)"; return 0; fi
    log "Deleting $WORKROOT"
    if [[ $(id -u) -ne 0 ]] && command -v podman >/dev/null 2>&1; then
        podman unshare rm -rf -- "$WORKROOT"   # files created under subuids
    else
        rm -rf -- "$WORKROOT"
    fi
}

# ---- Container mode ---------------------------------------------------------
run_in_docker() {
    local eng=$ENGINE
    if [[ -z $eng ]]; then
        if command -v docker >/dev/null 2>&1; then eng=docker
        elif command -v podman >/dev/null 2>&1; then eng=podman
        else die "--docker needs docker or podman on PATH"; fi
    fi
    command -v "$eng" >/dev/null 2>&1 || die "$eng not found on PATH"
    "$eng" info >/dev/null 2>&1 || die "$eng daemon is not reachable (is it running? do you have permission?)"

    if [[ $PURGE -eq 1 ]]; then
        log "Removing work volume $WORK_VOLUME"
        "$eng" volume rm -f "$WORK_VOLUME" >/dev/null
        return 0
    fi

    ensure_submodule
    mkdir -p "$OUTDIR"
    local out_abs cfg_abs
    out_abs=$(realpath -m "$OUTDIR")
    cfg_abs=$CONFIG

    local -a inner=(--in-container -B /work -o /out)
    local -a mounts=(-v "$ROOT:/src:ro" -v "$WORK_VOLUME:/work" -v "$out_abs:/out")
    if [[ $cfg_abs == "$ROOT"/* ]]; then
        inner+=(-c "/src/${cfg_abs#"$ROOT"/}")
    else
        mounts+=(-v "$(dirname "$cfg_abs"):/cfg:ro")
        inner+=(-c "/cfg/$(basename "$cfg_abs")")
    fi
    if [[ $FS_ONLY -eq 1 ]];     then inner+=(--fs-only); fi
    if [[ $IMAGE_ONLY -eq 1 ]];  then inner+=(--image-only); fi
    if [[ $INTERACTIVE -eq 1 ]]; then inner+=(--interactive); fi
    if [[ $CLEAN -eq 1 ]];       then inner+=(--clean); fi
    if [[ $APT_CACHE -eq 0 ]];   then inner+=(--no-apt-cache); fi
    if [[ $DRY_RUN -eq 1 ]];     then inner+=(--dry-run); fi
    if [[ ${#OVERRIDES[@]} -gt 0 ]]; then inner+=(-- "${OVERRIDES[@]}"); fi

    local -a tty=(-i)
    if [[ -t 0 && -t 1 ]]; then tty+=(-t); fi
    local -a envs=(-e DRONEOS_IN_CONTAINER=1 -e DRONEOS_ROOT=/src -e "DRONEOS_VERSION=$VERSION" -e "TERM=${TERM:-xterm}")
    if [[ -n ${SOURCE_DATE_EPOCH:-} ]]; then envs+=(-e "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"); fi

    local -a bargs=(build -t "$IMAGE_TAG")
    if [[ $REBUILD -eq 1 ]]; then bargs+=(--pull --no-cache); fi
    if [[ $DEPS -eq 1 ]]; then bargs+=(--pull); fi

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "$eng ${bargs[*]} $ROOT/docker"
        echo "$eng run --rm ${tty[*]} --privileged --hostname droneos-builder ${envs[*]} ${mounts[*]} $IMAGE_TAG ${inner[*]}"
        return 0
    fi

    log "Builder image $IMAGE_TAG"
    "$eng" "${bargs[@]}" "$ROOT/docker"
    if [[ $DEPS -eq 1 ]]; then
        log "Dependencies live in the builder image; it is up to date."
        return 0
    fi

    # arm64 binfmt handler in the host kernel (only needed on non-arm64 hosts).
    # Check the host first: a rootless engine cannot see or register it, but the
    # host may already have qemu-user-static + binfmt-support installed.
    if ! host_is_arm64 && ! binfmt_arm64_present; then
        if ! "$eng" run --rm --privileged --entrypoint sh "$IMAGE_TAG" -c \
                'mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc; test -e /proc/sys/fs/binfmt_misc/qemu-aarch64' >/dev/null 2>&1; then
            log "Registering the arm64 QEMU binfmt handler in the host kernel (tonistiigi/binfmt)"
            "$eng" run --rm --privileged tonistiigi/binfmt --install arm64 \
                || die "could not register the arm64 binfmt handler (rootless engine?). On the host run:
         sudo apt install qemu-user-static binfmt-support && sudo update-binfmts --enable qemu-aarch64"
        fi
    fi

    if [[ $SHELL_MODE -eq 1 ]]; then
        [[ -t 0 && -t 1 ]] || die "--shell needs a terminal"
        exec "$eng" run --rm -it --privileged --hostname droneos-builder "${envs[@]}" "${mounts[@]}" \
            --entrypoint bash "$IMAGE_TAG"
    fi

    log "Building in $eng ($IMAGE_TAG, work volume $WORK_VOLUME)"
    "$eng" run --rm "${tty[@]}" --privileged --hostname droneos-builder "${envs[@]}" "${mounts[@]}" \
        "$IMAGE_TAG" "${inner[@]}"
    if [[ $CLEAN -eq 0 && $FS_ONLY -eq 0 ]]; then log "Image(s) copied to $out_abs"; fi
}

# ---- Native mode ------------------------------------------------------------
run_native() {
    command -v dpkg >/dev/null 2>&1 \
        || die "rpi-image-gen needs a Debian-based host (dpkg/apt). On other distros use: ./build.sh --docker"
    ensure_submodule

    local staged=0
    if [[ $IN_CONTAINER -eq 1 ]] || fs_is_foreign "$ROOT"; then staged=1; fi
    if [[ -z $WORKROOT ]]; then
        if [[ $staged -eq 1 ]]; then
            WORKROOT="${XDG_CACHE_HOME:-$HOME/.cache}/droneos/work"
        else
            WORKROOT="$ROOT/work"
        fi
    fi
    WORKROOT=$(realpath -m "$WORKROOT")

    if [[ $PURGE -eq 1 ]]; then purge_native; return 0; fi

    mkdir -p "$WORKROOT"
    fs_is_foreign "$WORKROOT" \
        && die "work dir $WORKROOT is on '$(fs_type "$WORKROOT")'; rpi-image-gen needs a Linux filesystem here (pass -B <dir on ext4/btrfs/xfs>)"

    local SRC
    if [[ $staged -eq 1 ]]; then
        if [[ $IN_CONTAINER -eq 0 ]]; then
            info "sources are on '$(fs_type "$ROOT")' - building from a staged copy under $WORKROOT"
        fi
        SRC="$WORKROOT/src"
    else
        SRC=$ROOT
    fi
    IG="$SRC/rpi-image-gen"

    local CFG
    if [[ $CONFIG == "$ROOT"/* ]]; then CFG="$SRC/${CONFIG#"$ROOT"/}"; else CFG=$CONFIG; fi

    # The same overrides go to build and clean, so both see the same
    # chroot-<version> / deploy-<version> directories.
    local -a ov=("IGconf_artefact_version=$VERSION")
    if [[ $APT_CACHE -eq 1 ]]; then ov+=("IGconf_sys_apt_cachedir=$WORKROOT/apt-cache"); fi
    ov+=("${OVERRIDES[@]}")

    local -a cmd=("$IG/rpi-image-gen" build -S "$SRC" -c "$CFG" -B "$WORKROOT")
    if [[ $FS_ONLY -eq 1 ]];     then cmd+=(-f); fi
    if [[ $IMAGE_ONLY -eq 1 ]];  then cmd+=(-i); fi
    if [[ $INTERACTIVE -eq 1 ]]; then cmd+=(-I); fi
    cmd+=(-- "${ov[@]}")

    log "DroneOS image build"
    info "config:   $CFG"
    info "sources:  $SRC"
    info "work:     $WORKROOT"
    info "output:   $OUTDIR"
    info "version:  $VERSION"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%q ' "${cmd[@]}"; echo
        return 0
    fi

    if [[ $staged -eq 1 ]]; then stage_sources "$SRC"; fi

    if [[ $DEPS -eq 1 ]]; then
        install_deps
        deps_missing && { print_missing_deps; die "Dependencies are still missing after the install (see above)"; }
        check_binfmt
        log "Host dependencies OK"
        return 0
    fi
    if deps_missing; then
        print_missing_deps
        if [[ $IN_CONTAINER -eq 1 ]]; then
            die "The builder image lacks dependencies - rebuild it: ./build.sh --docker --rebuild (build.ps1 -Rebuild)"
        fi
        warn "Host dependencies are missing - installing them now (sudo may ask for your password)."
        install_deps
        deps_missing && { print_missing_deps; die "Dependencies are still missing after the install (see above)"; }
    fi
    check_binfmt
    fix_parent_perms "$WORKROOT"

    # bdebstrap is pip-installed into rpi-image-gen's private sysroot (--root);
    # Debian's PEP 668 guard would otherwise refuse a system-python pip install.
    export PIP_BREAK_SYSTEM_PACKAGES=1
    export PYTHONDONTWRITEBYTECODE=1

    if [[ $CLEAN -eq 1 ]]; then
        log "rpi-image-gen clean ($CFG)"
        # Answers every "Remove ...?" prompt with yes. Process substitution
        # rather than a pipe: yes(1) dying of SIGPIPE afterwards must not turn
        # into exit 141 under pipefail.
        "$IG/rpi-image-gen" clean -c "$CFG" -B "$WORKROOT" -- "${ov[@]}" < <(yes)
        # Upstream clean looks for IGconf_image_deploydir, which no layer sets;
        # the real variable is IGconf_deploy_dir, so the deploy set would pile
        # up in the work tree.
        local final="$WORKROOT/bootstrap/final.env" deploy
        if deploy=$(getvar IGconf_deploy_dir "$final") && [[ $deploy == "$WORKROOT"/* && -d $deploy ]]; then
            log "Removing $deploy"
            rm -rf -- "$deploy"
        fi
        return 0
    fi

    if [[ $APT_CACHE -eq 1 ]]; then mkdir -p "$WORKROOT/apt-cache"; fi

    local start=$SECONDS
    (cd "$SRC" && "${cmd[@]}")
    local took=$(( SECONDS - start ))
    log "rpi-image-gen finished in $((took / 60))m$((took % 60))s"

    if [[ $FS_ONLY -eq 1 ]]; then
        info "filesystem only (-f): no image to copy"
        return 0
    fi

    local final="$WORKROOT/bootstrap/final.env" name outdir suffix deploy
    [[ -r $final ]] || { warn "$final not found - cannot locate the image"; return 0; }
    name=$(getvar IGconf_image_name "$final") || die "IGconf_image_name missing in $final"
    outdir=$(getvar IGconf_image_outputdir "$final") || die "IGconf_image_outputdir missing in $final"
    suffix=$(getvar IGconf_image_suffix "$final") || suffix=img
    deploy=$(getvar IGconf_deploy_dir "$final") || deploy=''

    mkdir -p "$OUTDIR"
    local f found=0
    for f in "$outdir"/"$name"*."$suffix"; do
        [[ -f $f ]] || continue
        cp --sparse=always "$f" "$OUTDIR/"
        found=1
        info "$(du -h "$f" | cut -f1)  $OUTDIR/$(basename "$f")"
    done
    [[ $found -eq 1 ]] || die "No $name*.$suffix in $outdir"
    if [[ -n $deploy && -d $deploy ]]; then info "deploy set (zstd image, IDP archive, SBOM): $deploy"; fi
    log "Done. Flash with Raspberry Pi Imager (Use custom) or: sudo rpi-imager --cli $OUTDIR/$name.$suffix /dev/mmcblk0"
}

IG=''
if [[ $MODE == docker ]]; then
    run_in_docker
else
    run_native
fi
