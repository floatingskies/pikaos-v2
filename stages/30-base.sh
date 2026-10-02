#!/bin/bash
# PikaOS-v2 :: stage 30 :: base system
#
# Installs the packages every flavour shares, drops in the PikaOS base
# settings, the v2 microarch environment, the live user and the installer.

set -euo pipefail
ROOTFS="${ROOTFS:?}"
. /build/config/pika.conf
STATEDIR="$(dirname "${ROOTFS}")/state"

if [ -e "${STATEDIR}/base-done" ]; then echo ">>> base already done"; exit 0; fi

export APTENV="-o DPkg::Options::=--force-confnew -o DPkg::Options::=--force-confdef"
APT="apt-get -y -o DPkg::Options::=--force-confnew -o DPkg::Options::=--force-confdef"

chroot_run() { chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive "$@"; }

# Without /proc mounted, systemd-tmpfiles (pulled in by dozens of maintainer
# scripts: tpm-udev, gvfs, udisks2, ...) aborts with
#   "/proc/ is not mounted, but required for successful operation"
# and every package --configure fails. Mount the pseudo-filesystems for the
# duration of this stage.
mount_cleanup() {
  umount -lf "${ROOTFS}/dev/pts"   2>/dev/null || true
  umount -lf "${ROOTFS}/dev"       2>/dev/null || true
  umount -lf "${ROOTFS}/sys"       2>/dev/null || true
  umount -lf "${ROOTFS}/proc"      2>/dev/null || true
  umount -lf "${ROOTFS}/run"       2>/dev/null || true
  rm -f "${ROOTFS}/etc/resolv.conf"
}
trap mount_cleanup EXIT

mkdir -p "${ROOTFS}"/{proc,sys,dev/pts,run}
mount -t proc  proc  "${ROOTFS}/proc"
mount -t sysfs sys   "${ROOTFS}/sys"
mount --bind /dev   "${ROOTFS}/dev"
mount -t devpts devpts "${ROOTFS}/dev/pts"

# The bootstrap rootfs ships /etc/resolv.conf as a symlink to systemd's
# stub-resolv.conf, which does not exist inside a build chroot -> all apt
# lookups fail with "Temporary failure resolving". Replace it with a real file
# for the duration of the build.
rm -f "${ROOTFS}/etc/resolv.conf"
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "${ROOTFS}/etc/resolv.conf"

echo ">>> refreshing apt lists inside chroot"
chroot_run apt-get update

BASE_PKGS="
systemd-sysv udev dbus dbus-user-session
live-boot live-config live-boot-initramfs-tools initramfs-tools
# cpio is NOT pulled in by initramfs-tools on sid, and without it
# mkinitramfs silently produces a 0-byte main archive: the initrd ends up
# containing only the early microcode cpio, with no /init, no scripts/ and no
# live-boot, so the kernel can never mount the squashfs. It was masked by
# "update-initramfs ... || true". Install it explicitly and assert on it.
cpio zstd
sudo locales keyboard-configuration console-setup
plymouth
gdisk parted dosfstools f2fs-tools xfsprogs btrfs-progs rsync
e2fsprogs grub-efi-amd64 grub-pc-bin grub-common efibootmgr
network-manager nm-connection-editor iwd bluez bluez-tools
pavucontrol alsa-utils pipewire wireplumber
mesa-vulkan-drivers libgl1-mesa-dri libglx-mesa0 mesa-utils vainfo
firmware-linux-free firmware-realtek intel-microcode
flatpak xdg-user-dirs
python3-gi gir1.2-gtk-3.0 gir1.2-xapp-1.0 zenity packagekit
apparmor-utils
"

echo ">>> installing base packages"
chroot_run ${APT} install ${BASE_PKGS}

# ---- install our x86-64-v2 kernel ----------------------------------------
# sid's own linux-image-amd64 is far newer than the 6.16 we tuned for Ivy
# Bridge, and it is codegened for a generic baseline anyway. Ship ours.
KDEB=$(ls "$(dirname "${ROOTFS}")"/kernel/linux-image-*-pikaos_*.deb | tail -1)
echo ">>> installing kernel: $(basename "${KDEB}")"
cp "${KDEB}" "${ROOTFS}/tmp/"
chroot_run ${APT} install "/tmp/$(basename "${KDEB}")"
rm -f "${ROOTFS}/tmp/$(basename "${KDEB}")"

# Build the real initramfs. This must NOT be allowed to fail quietly: a
# silently-empty initrd boots to a dead kernel with no visible cause.
echo ">>> building initramfs"
chroot_run update-initramfs -u -k all

# Assert the initrd is actually usable. A microcode-only initrd is the classic
# symptom of a missing cpio, and it is invisible unless we look.
INITRD="${ROOTFS}/boot/initrd.img-${KVER_FULL:-6.16.12-pikaos}"
INITRD="$(ls "${ROOTFS}"/boot/initrd.img-* 2>/dev/null | head -1)"
[ -n "${INITRD}" ] || { echo "FATAL: no initrd produced"; exit 1; }
if ! lsinitramfs "${INITRD}" 2>/dev/null | grep -qx 'init'; then
  echo "FATAL: ${INITRD} has no /init -- it is microcode-only." >&2
  echo "       (almost always a missing 'cpio' in the rootfs)" >&2
  exit 1
fi
lsinitramfs "${INITRD}" 2>/dev/null | grep -q 'live-boot' \
  || { echo "FATAL: live-boot missing from ${INITRD}"; exit 1; }
ok "initramfs verified ($(du -h "${INITRD}" | cut -f1), has /init + live-boot)"

# ------------------------------------------------------------- hostname ----
echo "${LIVE_HOST}" > "${ROOTFS}/etc/hostname"
cat > "${ROOTFS}/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	${LIVE_HOST}
::1	localhost ip6-localhost ip6-loopback
ff02::1	ip6-allnodes
ff02::2	ip6-allrouters
EOF

# --------------------------------------------------- microarch disclosure ---
cat > "${ROOTFS}/etc/pika-release" <<EOF
NAME="PikaOS v2"
ID=pikav2
ID_LIKE=debian
VERSION_ID="${VERSION}"
VERSION_CODENAME=${CODENAME}
PRETTY_NAME="PikaOS v2 ${VERSION} (${CODENAME})"
TARGET_ARCH=x86-64-v2
TARGET_MARCH=${TARGET_MARCH}
HOME_URL="https://github.com/floatingskies/pikaos-v2"
SUPPORT_URL="https://github.com/floatingskies/pikaos-v2/issues"
EOF

# Every component we ship is compiled at -march=x86-64-v2; record the
# compiler flags used so in-image rebuilds inherit them.
mkdir -p "${ROOTFS}/etc/profile.d"
cat > "${ROOTFS}/etc/profile.d/00-pika-build-arch.sh" <<'EOF'
# PikaOS v2 :: the whole userland is compiled for x86-64-v2 (Sandy/Ivy Bridge).
export PIKA_BUILD_ARCH=amd64-v2
export GOAMD64=v2
EOF

cat > "${ROOTFS}/etc/apt/apt.conf.d/90pika-build-arch" <<EOF
// PikaOS v2 is a -march=x86-64-v2 build. Rebuild in-tree packages at the same
// level; do NOT let anything sneak in -mavx2 (Ivy Bridge would SIGILL).
Acquire::Retries "5";
APT::Install-Recommends "true";
EOF

mkdir -p "${ROOTFS}/etc/debian"
cat > "${ROOTFS}/etc/debian/rules" <<'EOF'
#!/usr/bin/make -f
// x86-64-v2 build of a Debian package (see pikaos-v2 config/build-config).
_V2 := -march=x86-64-v2 -mtune=generic -O3 -flto -fuse-linker-plugin -falign-functions=32
export DEB_BUILD_MAINT_OPTIONS := optimize=+lto $(_V2)
export DEB_CFLAGS_MAINT_APPEND := $(_V2)
export DEB_CPPFLAGS_MAINT_APPEND := $(_V2)
export DEB_CXXFLAGS_MAINT_APPEND := $(_V2)
export DEB_LDFLAGS_MAINT_APPEND := -march=x86-64-v2 -flto -fuse-linker-plugin
export DEB_BUILD_OPTIONS := nocheck notest terse
export DPKG_GENSYMBOLS_CHECK_LEVEL := 0
export GOAMD64 := v2
%:
	dh $@
EOF

# ------------------------------------------------------------- live user ---
# Create the account first, THEN set the password. chpasswd alone does nothing
# useful if the user does not exist yet.
if ! grep -q "^${LIVE_USER}:" "${ROOTFS}/etc/passwd"; then
  chroot_run useradd -m -s /bin/bash -U "${LIVE_USER}"
fi
mkdir -p "${ROOTFS}/home/${LIVE_USER}"

# chpasswd goes through PAM, which can refuse inside a build chroot. If it
# does, write the hash straight into /etc/shadow.
if ! echo "${LIVE_USER}:${LIVE_PASS}" | chroot_run chpasswd 2>/dev/null; then
  echo ">>> chpasswd failed in chroot; setting shadow hash directly"
  HASH=$(openssl passwd -6 "${LIVE_PASS}")
  if grep -q "^${LIVE_USER}:" "${ROOTFS}/etc/shadow"; then
    chroot_run usermod -p "${HASH}" "${LIVE_USER}"
  else
    echo "${LIVE_USER}:${HASH}:19000:0:99999:7:::" >> "${ROOTFS}/etc/shadow"
  fi
fi
chroot_run usermod -aG sudo,audio,video,plugdev,netdev,cdrom,dialout,bluetooth,lpadmin "${LIVE_USER}" || true

# --------------------------------------------------- pika-os unix tuning ---
# From upstream pkg-kernel-pika: these are PikaOS's own defaults.
install -Dm644 /build/upstream/pkg-kernel-pika/kernel-pika/usr/lib/sysctl.d/20-disable-split-lock-detect.conf \
  "${ROOTFS}/etc/sysctl.d/20-disable-split-lock-detect.conf"
install -Dm644 /build/upstream/pkg-kernel-pika/kernel-pika/usr/lib/sysctl.d/20-starcitizen-max_map_count.conf \
  "${ROOTFS}/etc/sysctl.d/20-starcitizen-max_map_count.conf"
install -Dm644 /build/upstream/pkg-kernel-pika/kernel-pika/usr/lib/sysctl.d/90-custom-mtu-probing.conf \
  "${ROOTFS}/etc/sysctl.d/90-custom-mtu-probing.conf"
install -Dm644 /build/upstream/pkg-kernel-pika/kernel-pika/usr/lib/modprobe.d/80-v4l2loopback.conf \
  "${ROOTFS}/etc/modprobe.d/80-v4l2loopback.conf"
install -Dm644 /build/upstream/pkg-kernel-pika/kernel-pika/usr/lib/pipewire/pipewire-pulse.conf.d/10-wine-audio.conf \
  "${ROOTFS}/etc/pipewire/pipewire-pulse.conf.d/10-wine-audio.conf"
install -Dm644 /build/upstream/pkg-kernel-pika/kernel-pika/usr/lib/udev/rules.d/39-hpet-permissions.rules \
  "${ROOTFS}/etc/udev/rules.d/39-hpet-permissions.rules"

cat > "${ROOTFS}/etc/sysctl.d/80-pika-v2.conf" <<'EOF'
# PikaOS v2 :: v2-era hardware defaults (Ivy Bridge class)
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.page-cluster = 0
# Ivy Bridge: leave the L3 shared, don't over-commit
kernel.nmi_watchdog = 0
# Old CPUs: disable the heavy mitigation scans
kernel.split_lock_detect = 0
# Faster boot on spinning rust
vm.laptop_mode = 5
EOF

# ----------------------------------------------------- hostname/branding --
mkdir -p "${ROOTFS}/etc/issue.d"
cat > "${ROOTFS}/etc/issue" <<EOF
PikaOS v2 \\\\n \\\\l

EOF

touch "${STATEDIR}/base-done"
echo ">>> stage30 complete"