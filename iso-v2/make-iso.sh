#! /bin/bash
# Host-side driver for the PikaOS-v2 live ISO build.
#
#   ./iso-v2/make-iso.sh [minimal|full]
#
# Builds the pika-iso-v2 container image if needed, then runs inner-build.sh
# inside a privileged container with the project root bind-mounted at /build.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
IMAGE="${ISO_BUILDER_IMAGE:-pika-iso-v2}"
MODE="${1:-minimal}"

case "$MODE" in
    minimal|full) ;;
    *) echo "usage: $0 [minimal|full]" >&2; exit 1 ;;
esac

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    if [ "${ISO_BUILDER_PULL:-0}" = 1 ] && docker pull "$IMAGE"; then
        :
    else
        echo "==> building container image $IMAGE"
        docker build -t "$IMAGE" "$HERE"
    fi
fi

echo "==> running ISO build (MODE=$MODE)"
exec docker run --rm \
    --privileged \
    --security-opt apparmor=unconfined \
    -e MODE="$MODE" \
    -v "$ROOT:/build" \
    -w /build/iso-v2 \
    "$IMAGE" \
    /bin/bash /build/iso-v2/inner-build.sh
