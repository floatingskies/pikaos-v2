# PikaOS-v2 :: build driver
#
#   ./build.sh bootstrap     -> chroot only
#   ./build.sh kernel        -> build v2 kernel
#   ./build.sh base          -> base system config
#   ./build.sh tools         -> rebuild PikaOS components for v2
#   ./build.sh flavour NAME  -> gnome | kde
#   ./build.sh iso           -> squashfs + ISOs for every finished flavour
#   ./build.sh all
#   ./build.sh verify-isa
#
# Stages run inside a privileged debian:sid container; state lives in out/.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"

IMAGE="pika-build:v2"
ROOTFS="${HERE}/out/rootfs"
WORK="/build"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

build_image() {
  if docker image inspect "${IMAGE}" >/dev/null 2>&1; then return 0; fi
  log "building build image ${IMAGE}"
  docker build -q -t "${IMAGE}" - <<'EOF'
FROM debian:sid-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      mmdebstrap debian-archive-keyring debootstrap \
      build-essential bc bison flex libssl-dev libelf-dev libdw-dev \
      debhelper debhelper-compat lsb-release fakeroot \
      xorriso mtools dosfstools gdisk parted squashfs-tools \
      syslinux-common isolinux syslinux \
      grub-efi-amd64-bin grub-pc-bin grub-common \
      ca-certificates curl wget git rsync \
      python3 python3-pip python3-setuptools \
      golang-go llvm clang cmake pkg-config \
      gawk gettext kmod cpio initramfs-tools \
      zstd lz4 xz-utils \
      busybox-static \
      qemu-utils && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /build
EOF
}

run_stage() {
  local stage="$1"
  log "stage ${stage}"
  docker run --rm --privileged \
    -v "${HERE}:${WORK}" \
    -v "${HERE}/out:/build/out" \
    -e "ROOTFS=${ROOTFS}" \
    -e "TARGET_FLAVOUR=${2:-}" \
    -e "ONLY_FLAVOURS=${ONLY_FLAVOURS:-}" \
    "${IMAGE}" bash -c "chmod +x ${WORK}/stages/*.sh && ${WORK}/stages/${stage}"
}

case "${1:-all}" in
  image)    build_image ;;
  *)        build_image
            for s in "${@}"; do
              case "${s}" in
                all)
                  run_stage 10-bootstrap.sh
                  run_stage 20-kernel.sh
                  run_stage 30-base.sh
                  run_stage 40-tools.sh
                  for f in gnome kde; do run_stage 50-flavour.sh "${f}"; done
                  run_stage 60-iso.sh
                  ;;
                gnome)     run_stage 50-flavour.sh gnome ;;
                kde)       run_stage 50-flavour.sh kde ;;
                iso)       run_stage 60-iso.sh ;;
                verify-isa) run_stage 70-verify-isa.sh ;;
                # resolve short names: bootstrap -> 10-bootstrap.sh
                *)         run_stage "$(ls stages | grep -E "^${s//./\\.}-" || echo "${s}.sh")" ;;
              esac
            done ;;
esac