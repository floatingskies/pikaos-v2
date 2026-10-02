#! /bin/bash
# Common variables for the PikaOS-v2 live ISO build.
#
# Method adapted from PikaOS images/live-iso-kde (git.pika-os.com):
#   UEFI-only, mksquashfs zstd-22, xorriso appended GPT EFI partition.
# Difference: the live rootfs boots via GRUB2 + Debian live-boot (instead of
# rEFInd + booster), and is Debian sid (x86-64 baseline) plus PikaOS components
# rebuilt for x86-64-v2 (see ../v2), instead of the v3 PikaOS nest image.

HERE="${HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ROOT="${ROOT:-$(cd "$HERE/.." && pwd)}"

export ISO_DISTNAME="WoofOSv2"
export ISO_DESKTOP="KDE"
export ISO_ARCH="amd64"
export ISO_RELEASE="4.0"
export ISO_PATCH="1"
export ISO_DATE="$(date +%y.%m.%d)"
export ISO_LABEL="WOOF $ISO_DATE $ISO_PATCH"
export ISO_IMAGE="$ISO_DISTNAME-$ISO_DESKTOP-$ISO_RELEASE-$ISO_ARCH-$(date +%F)-$ISO_PATCH"

export LIVE_HOSTNAME="woofos"
export LIVE_USER="woofos"
export LIVE_UID=1001
export LIVE_GECOS="WoofOS Live User"

export BUILD="$HERE/build"
export ROOTFS="$BUILD/rootfs"
export LIVE_PATH="$BUILD/live"
export EFIBOOT_IMG="$BUILD/efiboot.img"
export V2_REPO="$ROOT/v2/repo"
export GRUB_DATA="$HERE/data/grub"
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
live-boot live-boot-initramfs-tools
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

# PikaOS branding, KDE customisations and the PikaOS tool suite, all rebuilt for
# x86-64-v2 and installed from the local v2 repo (see v2/ci/packages.tsv for the
# fleet and why some entries are parked).
#
# This is the *buildable against plain Debian sid* subset: packages whose Depends
# chain only needs sid are included. Several PikaOS packages are deliberately
# absent because they depend on KF5/otter/pik-only helpers that sid no longer
# ships (pika-kde-desktop, pika-shell-profile-*, pika-kernel-manager,
# pika-device-manager, pika-welcome, pika-first-setup-gtk4, plymouth-theme-pika,
# pikman-update-manager, plasma-supergfxctl, falcond-gui). Those still build as
# standalone v2 debs; they are just not part of the full ISO recipe until their
# dependency closure is ported to KF6/sid.
#
# pika-installer-gtk4 is absent on purpose: iso-v2/inner-build.sh stages the
# in-tree config/pika-install as /usr/bin/pika-install plus its own launcher and
# polkit rule, and the GTK4 helper would shadow it.
export PIKA_PKGS="
pika-wallpapers sound-theme-pika papirus-colors plymouth-theme-pika
pika-kde-desktop pika-kde-settings plasma-supergfxctl kio-admin
pika-shell-profile-common pika-shell-profile-otter
pika-welcome pika-first-setup-gtk4
pika-installer-gtk4
pikman pikman-update-manager apx popsicle-gtk falcond-gui
pika-apx-configs pika-sources
libpam-any libpam-parallel apt-btrfs-snapper
ananicy-cpp ananicy-rules dmemcg-booster
pika-audio-pipewire pika-baseos-desktop
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
efibootmgr grub-efi-amd64-bin
"
