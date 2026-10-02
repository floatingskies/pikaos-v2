#! /bin/bash
# PikaOS-v2 live ISO pipeline. Runs INSIDE the privileged pika-iso-v2 container
# with the project root bind-mounted at /build. UEFI-only, GRUB2 + Debian
# live-boot + xorriso, but the rootfs is built from Debian sid plus the local
# x86-64-v2 PikaOS repo.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
. "$HERE/info.sh"

MODE="${MODE:-minimal}"

LIVE_BOOT_PATH="$BUILD/LIVE_BOOT"
LIVE_BOOT_DATA_PATH="$LIVE_BOOT_PATH/data"
LIVE_BOOT_LIVE_PATH="$LIVE_BOOT_DATA_PATH/live"
ROOTFS_PATH="$LIVE_BOOT_PATH/rootfs"
EFIBOOT_IMG="$LIVE_BOOT_PATH/efiboot.img"
GRUB_TMP="$LIVE_BOOT_PATH/grub"
REPO_MNT="/opt/v2repo"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

case "$MODE" in
    minimal) PKGS="$BASE_PKGS $INSTALLER_PKGS" ;;
    full)    PKGS="$BASE_PKGS $INSTALLER_PKGS $FIRMWARE_PKGS $DESKTOP_PKGS" ;;
    *)       die "unknown MODE '$MODE' (use minimal|full)" ;;
esac

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
MOUNTS=()
umount_all() {
    set +e
    local m
    for (( idx=${#MOUNTS[@]}-1; idx>=0; idx-- )); do
        m="${MOUNTS[$idx]}"
        umount "$m" 2>/dev/null || umount -lf "$m" 2>/dev/null
    done
}
trap umount_all EXIT

# ---------------------------------------------------------------------------
# 0. index the local x86-64-v2 repo
# ---------------------------------------------------------------------------
log "indexing local v2 repo: $V2_REPO"
[ -d "$V2_REPO/pool/main" ] || die "no v2 packages in $V2_REPO/pool/main (run ../v2/pkg-build.sh first)"
ls "$V2_REPO"/pool/main/*.deb >/dev/null 2>&1 || die "v2 repo has no .deb files"
# v2/ci/repo-index.sh already produced a self-consistent Packages/Packages.gz/
# Release set (Release carries the checksums apt verifies). Regenerating here
# with a different gzip level would change Packages.gz and make apt reject the
# Release hashes ("Hash Sum mismatch"), so only build the index when missing.
if [ ! -s "$V2_REPO/Packages" ] || [ ! -s "$V2_REPO/Packages.gz" ]; then
    log "no prebuilt index in $V2_REPO; generating one"
    (
        cd "$V2_REPO"
        rm -f Packages Packages.gz Release
        dpkg-scanpackages --multiversion pool/main /dev/null > Packages 2>/dev/null
        gzip -9 -kf Packages
    )
fi

# ---------------------------------------------------------------------------
# 1. bootstrap a minimal Debian sid rootfs
# ---------------------------------------------------------------------------
log "debootstrap Debian sid (x86-64 baseline) -> $ROOTFS_PATH"
umount_all
rm -rf "$LIVE_BOOT_PATH"
mkdir -p "$ROOTFS_PATH" "$LIVE_BOOT_LIVE_PATH" "$BUILD/output"
debootstrap \
    --arch=amd64 \
    --variant=minbase \
    --components=main,contrib,non-free,non-free-firmware \
    sid "$ROOTFS_PATH" http://deb.debian.org/debian

# ---------------------------------------------------------------------------
# 2. enter the chroot and install everything
# ---------------------------------------------------------------------------
log "mounting pseudo-filesystems"
install -m 0644 /etc/resolv.conf "$ROOTFS_PATH/etc/resolv.conf"
mkdir -p "$ROOTFS_PATH$REPO_MNT"
mount --bind "$V2_REPO" "$ROOTFS_PATH$REPO_MNT"; MOUNTS+=("$ROOTFS_PATH$REPO_MNT")
mount -t proc proc "$ROOTFS_PATH/proc" -o nosuid,nodev,noexec;   MOUNTS+=("$ROOTFS_PATH/proc")
mount -t sysfs sys "$ROOTFS_PATH/sys" -o nosuid,nodev,noexec,ro; MOUNTS+=("$ROOTFS_PATH/sys")
mount --bind /dev "$ROOTFS_PATH/dev";                            MOUNTS+=("$ROOTFS_PATH/dev")
mount -t tmpfs run "$ROOTFS_PATH/run" -o mode=0755,nosuid,nodev; MOUNTS+=("$ROOTFS_PATH/run")

rm -f "$ROOTFS_PATH"/etc/apt/sources.list.d/*
cat > "$ROOTFS_PATH/etc/apt/sources.list" <<EOF
deb http://deb.debian.org/debian sid main contrib non-free non-free-firmware
deb [trusted=yes] file:$REPO_MNT ./
EOF

log "apt-get install ($MODE packages)"
PKGS_LINE="$(printf '%s' "$PKGS" | tr '\n' ' ')"
if [ "$MODE" = full ]; then APT_OPTS=""; else APT_OPTS="--no-install-recommends"; fi
chroot "$ROOTFS_PATH" /usr/bin/env PKGS="$PKGS_LINE" APT_OPTS="$APT_OPTS" /bin/bash -c '
    set -eo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y $APT_OPTS $PKGS
    apt-get clean
' || die "package installation failed"

# ---------------------------------------------------------------------------
# 2b. stage the on-ISO installer (works offline), its desktop launcher and the
#     polkit rule that lets the live user run it without a password prompt.
# ---------------------------------------------------------------------------
log "staging the installer (pika-install)"
install -Dm0755 "$ROOT/config/pika-install"    "$ROOTFS_PATH/usr/bin/pika-install"
install -Dm0755 "$ROOT/config/pika-cpuidetect" "$ROOTFS_PATH/usr/bin/pika-cpuidetect"
ln -sf /usr/bin/pika-install "$ROOTFS_PATH/usr/sbin/pika-install"

install -d "$ROOTFS_PATH/usr/share/applications"
cat > "$ROOTFS_PATH/usr/share/applications/pika-install.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Install PikaOS v2
Name[pt_BR]=Instalar PikaOS v2
Comment=Install PikaOS v2 to your disk (x86-64-v2)
Exec=pkexec /usr/bin/pika-install
Icon=drive-harddisk
Terminal=true
Categories=System;
Keywords=install;installer;setup;
EOF

install -d "$ROOTFS_PATH/etc/polkit-1/rules.d"
cat > "$ROOTFS_PATH/etc/polkit-1/rules.d/49-pika-install.rules" <<'EOF'
// Let members of the live "sudo" group launch the installer without a prompt.
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/usr/bin/pika-install" &&
        subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
EOF

log "configuring live rootfs"
cat > "$ROOTFS_PATH/root/live.env" <<EOF
LIVE_HOSTNAME='$LIVE_HOSTNAME'
LIVE_USER='$LIVE_USER'
LIVE_UID='$LIVE_UID'
LIVE_GECOS='$LIVE_GECOS'
LIVE_PASS='pika'
EOF
install -m 0755 "$HERE/config/live-setup.sh" "$ROOTFS_PATH/root/live-setup.sh"
chroot "$ROOTFS_PATH" /bin/bash /root/live-setup.sh || die "live-setup failed"

log "resolving kernel + initrd"
ISO_KERNEL="$(basename "$(ls "$ROOTFS_PATH"/boot/vmlinuz-* | head -1)" | sed 's/^vmlinuz-//')"
[ -f "$ROOTFS_PATH/boot/initrd.img-$ISO_KERNEL" ] || die "initrd.img-$ISO_KERNEL not produced"
echo "kernel: $ISO_KERNEL"

umount_all
rm -rf "$ROOTFS_PATH$REPO_MNT" "$ROOTFS_PATH/root/live.env" "$ROOTFS_PATH/root/live-setup.sh"

# ---------------------------------------------------------------------------
# 3. squashfs
# ---------------------------------------------------------------------------
log "mksquashfs (zstd-22) -> $LIVE_BOOT_LIVE_PATH/filesystem.squashfs"
rm -f "$LIVE_BOOT_LIVE_PATH/filesystem.squashfs"
mksquashfs \
    "$ROOTFS_PATH" \
    "$LIVE_BOOT_LIVE_PATH/filesystem.squashfs" \
    -noappend \
    -comp zstd \
    -Xcompression-level 22 \
    -b 1M \
    -no-progress
[ -s "$LIVE_BOOT_LIVE_PATH/filesystem.squashfs" ] || die "squashfs was not created"
printf '%s\n' zstd > "$LIVE_BOOT_LIVE_PATH/.comp"

# ---------------------------------------------------------------------------
# 4. assemble the GRUB2 ESP (GRUB EFI + kernel + initrd on the FAT partition)
# ---------------------------------------------------------------------------
log "building GRUB2 ESP"
rm -rf "$GRUB_TMP"
mkdir -p "$GRUB_TMP/EFI/BOOT"
cp -f "$ROOTFS_PATH/boot/vmlinuz-$ISO_KERNEL"    "$GRUB_TMP/EFI/vmlinuz"
cp -f "$ROOTFS_PATH/boot/initrd.img-$ISO_KERNEL" "$GRUB_TMP/EFI/initrd"

# Render grub.cfg and embed it inside a standalone EFI binary, so the ESP needs
# no separate config file: grub-mkstandalone places it at boot/grub/grub.cfg.
cp -f "$GRUB_DATA/grub.cfg" "$GRUB_TMP/grub.cfg"
sed -i "s#THE_NAME_OF_CURRENT_ISO_FOR_VENTOY#$ISO_IMAGE.iso#g" "$GRUB_TMP/grub.cfg"
grub-mkstandalone \
    --format=x86_64-efi \
    --output="$GRUB_TMP/EFI/BOOT/BOOTX64.EFI" \
    --modules="part_gpt part_msdos fat exfat ntfs linux normal iso9660 search search_label search_fs_uuid all_video gfxterm gfxmenu font videoinfo echo test configfile serial terminfo" \
    --locales="" \
    --themes="" \
    "boot/grub/grub.cfg=$GRUB_TMP/grub.cfg"

# Drop the unpacked rootfs before xorriso to save workspace.
rm -rf "$ROOTFS_PATH"

EFI_BOOT_IMAGE_SIZE=$(( $(du -s -B1048576 "$GRUB_TMP" | cut -f1) + 10 ))
rm -f "$EFIBOOT_IMG"
dd if=/dev/zero of="$EFIBOOT_IMG" bs=1M count="$EFI_BOOT_IMAGE_SIZE" status=none
mkfs.vfat -F 32 "$EFIBOOT_IMG" >/dev/null

(
    cd "$GRUB_TMP"
    while IFS= read -r -d '' d; do
        mmd -i "$EFIBOOT_IMG" "::$(printf '%s' "$d" | tr '[:lower:]' '[:upper:]')"
    done < <(find EFI -type d -print0 | sort -z)
    while IFS= read -r -d '' f; do
        mcopy -i "$EFIBOOT_IMG" "$f" "::$(printf '%s' "$f" | tr '[:lower:]' '[:upper:]')"
    done < <(find EFI -type f -print0)
)

# ---------------------------------------------------------------------------
# 5. build the ISO
# ---------------------------------------------------------------------------
log "xorriso -> ISO"
ISO_OUTPUT="$BUILD/output/$ISO_IMAGE.iso"
MD5_OUTPUT="$BUILD/output/$ISO_IMAGE.md5"
ISO_REQUIRED_SECTORS=$(du -s -B2048 "$LIVE_BOOT_DATA_PATH" "$EFIBOOT_IMG" | awk '{ total += $1 } END { print total }')
ISO_AVAILABLE_SECTORS=$(df -P -B2048 "$BUILD/output" | awk 'NR == 2 { print $4 }')
if [ "$ISO_AVAILABLE_SECTORS" -le "$ISO_REQUIRED_SECTORS" ]; then
    die "not enough free space: required ${ISO_REQUIRED_SECTORS}s, available ${ISO_AVAILABLE_SECTORS}s"
fi

rm -f "$ISO_OUTPUT" "$MD5_OUTPUT"
xorriso \
    -as mkisofs \
    -iso-level 3 \
    -V "$ISO_LABEL" \
    -partition_offset 16 \
    -appended_part_as_gpt \
    -no-pad \
    -no-emul-boot \
    -append_partition 2 0xef "$EFIBOOT_IMG" \
    --efi-boot --interval:appended_partition_2:all:: \
    -o "$ISO_OUTPUT" \
    "$LIVE_BOOT_DATA_PATH"

md5sum "$ISO_OUTPUT" > "$MD5_OUTPUT"
log "done: $ISO_OUTPUT"
ls -lh "$ISO_OUTPUT" "$MD5_OUTPUT"
