#!/bin/bash
# PikaOS-v2 :: stage 40 :: PikaOS components rebuilt for x86-64-v2
#
# Upstream PikaOS compiles its own packages with
#   DEB_*_MAINT_APPEND="-march=x86-64-v3 -O3 -flto"  (pika-build-config/amd64-v3.sh)
# We run the exact same pipeline against our config/build-config/amd64-v2.sh,
# so every PikaOS component lands at x86-64-v2 instead. That is the whole
# point of this image: identical components, correct microarch.

set -euo pipefail
ROOTFS="${ROOTFS:?}"
. /build/config/pika.conf
STATEDIR="$(dirname "${ROOTFS}")/state"
OUT="$(dirname "${ROOTFS}")/pkgs"

if [ -e "${STATEDIR}/tools-done" ]; then echo ">>> tools already rebuilt"; exit 0; fi
mkdir -p "${OUT}" "${STATEDIR}"

# The v2 flag set, sourced for real this time.
# shellcheck source=/dev/null
source /build/config/build-config/amd64-v2.sh
echo ">>> building PikaOS components at -march=${TARGET_MARCH} (PIKA_BUILD_ARCH=${PIKA_BUILD_ARCH})"

# ---- pikman (Go) ---------------------------------------------------------
# Go has no -march; GOAMD64=v2 is the equivalent level (from our build-config).
# Dependencies are vendored in-tree and GOPROXY is off, so this build never
# touches the network and never tracks an upstream revision.
echo ">>> pikman: GOAMD64=${GOAMD64} (vendored, offline)"
cd /build/upstream/pikman
mkdir -p "${OUT}/pikman/usr/bin"
GOFLAGS=-mod=vendor GOPROXY=off GOAMD64="${GOAMD64}" \
  go build -ldflags="-s -w" -o "${OUT}/pikman/usr/bin/pikman" -buildvcs=false
file "${OUT}/pikman/usr/bin/pikman"

# ---- pika-welcome (Python/GTK) ------------------------------------------
# Pure script package; install as-is (no compiled code to re-target).
mkdir -p "${OUT}/pika-welcome"
cp -a /build/upstream/welcome-app/usr "${OUT}/pika-welcome/"

# ---- kernel-pika-config (udev/sysctl/modprobe/pipewire) ------------------
mkdir -p "${OUT}/kernel-pika-config"
cp -a /build/upstream/pkg-kernel-pika/kernel-pika/usr "${OUT}/kernel-pika-config/"

# ---- pika-theme (GDM wallpaper + theme hooks) ----------------------------
mkdir -p "${OUT}/pika-theme"
cp -a /build/upstream/pkg-pika-theme/pika-theme/usr "${OUT}/pika-theme/"
mkdir -p "${OUT}/pika-gdm-theme"
cp -a /build/upstream/pkg-pika-theme/pika-theme/usr/bin "${OUT}/pika-gdm-theme/usr/"

# ---- wallpapers ----------------------------------------------------------
mkdir -p "${OUT}/pika-wallpapers/usr/share"
cp -a /build/upstream/pkg-pika-wallpapers/backgrounds "${OUT}/pika-wallpapers/usr/share/"

# ---- desktop settings (skel) --------------------------------------------
mkdir -p "${OUT}/pika-gnome-settings"
cp -a /build/upstream/pkg-pika-gnome-settings/pika-gnome-settings/usr \
      "${OUT}/pika-gnome-settings/"
cp -a /build/upstream/pkg-pika-gnome-settings/pika-gnome-settings/etc \
      "${OUT}/pika-gnome-settings/"

mkdir -p "${OUT}/pika-kde-settings"
cp -a /build/upstream/pkg-pika-kde-settings/pika-kde-settings/usr \
      "${OUT}/pika-kde-settings/"
cp -a /build/upstream/pkg-pika-kde-settings/pika-kde-settings/etc \
      "${OUT}/pika-kde-settings/"
cp -a /build/upstream/pkg-pika-kde-settings/pika-kde-settings/etc/sddm.conf.d \
      "${OUT}/pika-kde-settings/etc/"

# ---- install into the rootfs --------------------------------------------
echo ">>> installing rebuilt components into rootfs"
install -Dm755 "${OUT}/pikman/usr/bin/pikman" "${ROOTFS}/usr/bin/pikman"

cp -a "${OUT}/pika-welcome/usr/." "${ROOTFS}/usr/"
cp -a "${OUT}/kernel-pika-config/usr/." "${ROOTFS}/usr/"
cp -a "${OUT}/pika-theme/usr/." "${ROOTFS}/usr/"
mkdir -p "${ROOTFS}/usr/share/backgrounds"
cp -a "${OUT}/pika-wallpapers/usr/share/backgrounds/." "${ROOTFS}/usr/share/backgrounds/"
ln -sfn /usr/share/backgrounds/pika "${ROOTFS}/usr/share/wallpapers/pika"

# skel bits land in /etc/skel so the live user's first boot picks them up
cp -a "${OUT}/pika-gnome-settings/etc/." "${ROOTFS}/etc/"
cp -a "${OUT}/pika-kde-settings/etc/." "${ROOTFS}/etc/"

touch "${STATEDIR}/tools-done"
echo ">>> stage40 complete"