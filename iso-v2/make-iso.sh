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

# Resolve the container engine once. CI has docker; a local host may only have
# podman, and hardcoded `docker` calls died with "command not found" here before
# any work started -- the same bug v2/pkg-build.sh had.
if [ -n "${CONTAINER_ENGINE:-}" ]; then
    ENGINE="$CONTAINER_ENGINE"
else
    ENGINE=""
    for cand in docker podman; do
        if command -v "$cand" >/dev/null 2>&1; then ENGINE="$cand"; break; fi
    done
fi
[ -n "$ENGINE" ] || {
    echo "error: no container runtime found (need docker or podman, or set CONTAINER_ENGINE)" >&2
    exit 2
}

case "$MODE" in
    minimal|full) ;;
    *) echo "usage: $0 [minimal|full]" >&2; exit 1 ;;
esac

# mmdebstrap mounts loop devices and xorriso writes an El Torito image, which is
# why the run needs --privileged. Under rootless podman that is not available,
# and failing deep inside inner-build.sh after twenty minutes of debootstrap is
# a much worse way to learn it than being told now.
if [ "$ENGINE" = podman ] && [ "${ISO_ROOTLESS:-1}" = 1 ] && [ "$(id -u)" != 0 ]; then
    if podman info --format '{{ .Host.Security.Rootless }}' 2>/dev/null | grep -qi true; then
        cat >&2 <<'EOF'
error: the ISO build needs --privileged (loop mounts for mmdebstrap, El Torito
       writes for xorriso) and this is a rootless podman.

Options:
  * run it as root, where rootless podman is not in play
  * set ISO_ROOTLESS=0 if you have configured podman for privileged containers
  * run the ISO build in CI instead (iso.yml), which uses docker
EOF
        exit 3
    fi
fi

if ! $ENGINE image inspect "$IMAGE" >/dev/null 2>&1; then
    if [ "${ISO_BUILDER_PULL:-0}" = 1 ] && $ENGINE pull "$IMAGE"; then
        :
    else
        echo "==> building container image $IMAGE with $ENGINE"
        $ENGINE build -t "$IMAGE" "$HERE"
    fi
fi

echo "==> running ISO build (MODE=$MODE, engine=$ENGINE)"
exec $ENGINE run --rm \
    --privileged \
    --security-opt apparmor=unconfined \
    -e MODE="$MODE" \
    -v "$ROOT:/build" \
    -w /build/iso-v2 \
    "$IMAGE" \
    /bin/bash /build/iso-v2/inner-build.sh
