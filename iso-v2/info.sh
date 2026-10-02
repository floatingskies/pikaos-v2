#! /bin/bash
# Common variables for the PikaOS-v2 live ISO build.
#
# Method adapted from PikaOS images/live-iso-kde (git.pika-os.com):
#   UEFI-only, rEFInd boot menu, booster initramfs with pika-live-booster-hooks,
#   mksquashfs zstd-22, xorriso appended GPT EFI partition.
# Difference: the rootfs is Debian sid (x86-64 baseline) plus PikaOS components
# rebuilt for x86-64-v2 (see ../v2), instead of the v3 PikaOS nest image.

HERE="${HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ROOT="${ROOT:-$(cd "$HERE/.." && pwd)}"

export ISO_DISTNAME="PikaOSv2"
export ISO_DESKTOP="KDE"
export ISO_ARCH="amd64"
export ISO_RELEASE="4.0"
export ISO_PATCH="1"
export ISO_DATE="$(date +%y.%m.%d)"
export ISO_LABEL="PKV2 $ISO_DATE $ISO_PATCH"
export ISO_IMAGE="$ISO_DISTNAME-$ISO_DESKTOP-$ISO_RELEASE-$ISO_ARCH-$(date +%F)-$ISO_PATCH"

export LIVE_HOSTNAME="pikaos"
export LIVE_USER="pikaos"
export LIVE_UID=1001
export LIVE_GECOS="PikaOS Live User"

export BUILD="$HERE/build"
export ROOTFS="$BUILD/rootfs"
export LIVE_PATH="$BUILD/live"
export EFIBOOT_IMG="$BUILD/efiboot.img"
export V2_REPO="$ROOT/v2/repo"
export REFIND_DATA="$HERE/data/refind"
export OUTPUT="$BUILD/output"

# Kernel shipped on the ESP, resolved after the rootfs is built.
export ISO_KERNEL="${ISO_KERNEL:-}"

# Packages installed into the live rootfs. Base = Debian sid (baseline x86-64,
# v2-safe). PikaOS-specific packages come from the local v2 repo. Desktop
# packages are appended depending on MODE.
export BASE_PKGS="
systemd systemd-sysv init udev dbus
kmod apt apt-utils sudo
kbd console-setup console-setup-linux locales tzdata
ca-certificates curl wget gnupg
iproute2 iputils-ping dhcpcd-base
pciutils usbutils
e2fsprogs util-linux mount
linux-image-amd64
initramfs-tools
busybox
lvm2 libdevmapper1.02.1 libdevmapper-event1.02.1 binutils console-data lz4
booster pika-live-booster-hooks
"

export FIRMWARE_PKGS="
firmware-linux
intel-microcode
amd64-microcode
"

export DESKTOP_PKGS="
kde-plasma-desktop sddm
sddm-theme-debian-breeze
konsole dolphin plasma-nm plasma-pa kde-config-gtk-style
systemsettings kwin-x11 xserver-xorg xserver-xorg-video-all xserver-xorg-input-all
"

# Installer + offline tooling. The installed system is produced by rsyncing the
# live rootfs, so these packages end up both on the ISO and in the target:
# partitioning (gdisk/parted/dosfstools), GRUB (common + both platforms),
# EFI NVRAM (efibootmgr), dual-boot detection (os-prober), polkit (pkexec) and
# a small GUI helper for the compatibility launcher (zenity).
export INSTALLER_PKGS="
gdisk parted dosfstools rsync fdisk efibootmgr os-prober
grub-common grub-efi-amd64-bin grub-pc-bin
pkexec polkitd zenity
"

# Packages for the on-ISO pool (installer may need them without network).
export POOL_PKGS="
efibootmgr refind grub-efi-amd64-bin
"
