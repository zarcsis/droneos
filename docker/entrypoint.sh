#!/bin/sh
# Container entry point for the droneos builder image.
#
# The droneos checkout is bind-mounted (read-only) at $DRONEOS_ROOT (/src by
# default). A checkout made on Windows may carry CRLF line endings, so build.sh
# is copied to /tmp with CRs stripped before it runs; build.sh then stages the
# rest of the tree into /work with the same treatment. Every argument is
# forwarded to build.sh unchanged.
set -e

src=${DRONEOS_ROOT:-/src}
if [ ! -f "$src/build.sh" ]; then
    echo "droneos-entrypoint: $src/build.sh not found - mount the droneos checkout at $src" >&2
    exit 2
fi

sed 's/\r$//' "$src/build.sh" > /tmp/droneos-build.sh
export DRONEOS_IN_CONTAINER=1
export DRONEOS_ROOT="$src"
exec bash /tmp/droneos-build.sh "$@"
