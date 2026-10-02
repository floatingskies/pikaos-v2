#!/bin/bash
# PikaOS-v2 :: stage 20 :: kernel
#
# Builds a kernel from Debian's linux source, configured for the x86-64-v2
# (Sandy/Ivy Bridge) target and carrying PikaOS's own tuning knobs
# (from upstream pkg-kernel-pika).
#
# Kernel code itself is not -march tuned in the dangerous sense (we keep
# -mtune=generic), but we do:
#   * keep the baseline x86-64-v2 ISA level for any inline asm / crypto
#   * enable the modules Ivy Bridge actually needs (i915, snd-hda-intel,
#     e1000e for the common OEM NIC, kvm-intel)
#   * ship PikaOS's sysctl/udev/modprobe/pipewire config

set -euo pipefail
ROOTFS="${ROOTFS:?}"
. /build/config/pika.conf

KVER="$(echo "${KERNEL_VER}" | cut -d- -f1)"
OUT="$(dirname "${ROOTFS}")/kernel"
SRC="${OUT}/linux-${KVER}"
STATEDIR="$(dirname "${ROOTFS}")/state"

if [ -e "${STATEDIR}/kernel-done" ]; then
  echo ">>> kernel already built: $(cat "${STATEDIR}/kernel-version")"
  exit 0
fi

mkdir -p "${OUT}"

if [ ! -d "${SRC}" ]; then
  echo ">>> fetching linux ${KVER} source"
  mkdir -p "${SRC}"
  # Debian pool layout: pool/main/l/linux/
  cd "${SRC}"
  wget -q "http://deb.debian.org/debian/pool/main/l/linux/linux_${KVER}.orig.tar.xz" \
    || wget -q "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER}.tar.xz"
  tar xf linux_*.orig.tar.xz --strip-components=1 2>/dev/null \
    || tar xf linux-*.tar.xz --strip-components=1
fi

cd "${SRC}"

# Always (re)generate the base config, then apply our fragment on top, so the
# fragment is the single source of truth for tuning. Rebuilding the kernel must
# not inherit a stale .config from a previous (possibly broken) fragment.
#
# NOTE: plain `make defconfig` on 6.16 yields a near-empty config with no
# CONFIG_NET at all, which produces a kernel with no networking. Use the real
# x86_64 defconfig as the base instead.
make -s x86_64_defconfig

# ---------------------------------------------------------------- tuning ----
# Order matters: the BASE config must come first, our fragment last, so the
# fragment's values win. Passing the fragment first makes merge_config treat it
# as the base and silently discard our x86_64_defconfig drivers.
./scripts/kconfig/merge_config.sh -m -O . \
  .config /build/config/kernel/pika-v2.fragment >/dev/null

make -s olddefconfig

# Sanity: the drivers Ivy Bridge needs must actually be present, otherwise the
# image has no graphics/audio/network on the target hardware.
missing=""
for sym in CONFIG_DRM_I915 CONFIG_SND_HDA_INTEL CONFIG_E1000E CONFIG_MODULES \
           CONFIG_AGP_INTEL CONFIG_ATA_PIIX CONFIG_BTRFS_FS CONFIG_BLK_DEV_NVME \
           CONFIG_BT_HCIBTUSB CONFIG_OVERLAY_FS; do
  grep -q "^${sym}=y" .config || missing="${missing} ${sym}"
done
if [ -n "${missing}" ]; then
  echo "!!! kernel fragment failed to set:${missing}" >&2
  echo "--- relevant .config lines ---" >&2
  grep -E 'CONFIG_DRM_I915|CONFIG_SND_HDA_INTEL|CONFIG_E1000E|CONFIG_MODULES=' .config >&2
  exit 1
fi
echo ">>> kernel config sanity check passed (i915, snd-hda-intel, e1000e, modules)"

echo ">>> building kernel ${KERNEL_VER}"
make -s -j"$(nproc)" \
  KBUILD_BUILD_VERSION="${KERNEL_VER}" \
  LOCALVERSION="-pikaos" \
  bindeb-pkg

DEBS=$(ls ../linux-image-*.deb ../linux-headers-*.deb 2>/dev/null | grep -v dbg || true)
echo ">>> built: ${DEBS}"
echo "${KERNEL_VER}-pikaos" > "${STATEDIR}/kernel-version"
touch "${STATEDIR}/kernel-done"