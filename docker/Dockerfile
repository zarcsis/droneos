# droneos builder image: Debian trixie plus everything rpi-image-gen needs.
# Built and run by build.sh --docker and build.ps1; not meant to be used by hand.
#
#   docker build -t droneos-builder:trixie docker/
#   docker run --rm -it --privileged \
#       -v <droneos checkout>:/src:ro -v droneos-work:/work -v <out dir>:/out \
#       droneos-builder:trixie [build.sh options]
#
# --privileged is mandatory: mmdebstrap mounts proc/sys/devpts inside a mount
# namespace and needs CAP_SYS_ADMIN for that. The arm64 binfmt handler is NOT
# part of this image - it lives in the host kernel (Docker Desktop VM or a Linux
# host); build.sh / build.ps1 register it with tonistiigi/binfmt when missing.
# The container runs as root, so rpi-image-gen's bin/ns skips podman unshare;
# podman is still installed because rpi-image-gen's dependency check wants it.
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1

# Package list = rpi-image-gen/depends (v2.8.0) + tools its scripts call without
# declaring (zstd, file, git) + foreign-arch helpers (qemu-user-static, arch-test)
# + setuptools/wheel so pip can build the bdebstrap wheel without downloading them.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash coreutils grep rsync curl ca-certificates git file xz-utils zstd zip \
        python3 python3-yaml python3-debian python3-jsonschema \
        python3-pip python3-setuptools python3-wheel \
        dpkg-dev debian-archive-keyring mmdebstrap \
        podman uidmap dbus-user-session \
        dosfstools e2fsprogs btrfs-progs mtools pv dctrl-tools uuid-runtime fdisk \
        cryptsetup-bin \
        make build-essential autoconf automake libtool autopoint flex gettext pkgconf \
        qemu-user-static arch-test \
    && rm -rf /var/lib/apt/lists/*

# Entry point: normalises the line endings of the mounted build.sh and runs it.
# sed -i covers the case where entrypoint.sh itself was checked out with CRLF.
COPY entrypoint.sh /usr/local/bin/droneos-entrypoint
RUN sed -i 's/\r$//' /usr/local/bin/droneos-entrypoint \
    && chmod 0755 /usr/local/bin/droneos-entrypoint

VOLUME ["/work"]
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/droneos-entrypoint"]
