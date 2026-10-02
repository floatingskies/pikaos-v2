#! /bin/bash
# Rebuild only the GRUB2 ESP + ISO from an existing LIVE_BOOT tree, reusing
# data/live/filesystem.squashfs and grub/. Fast iteration replacement for a
# full inner-build.sh run. Run as root (the tree is root-owned) and with
# grub-mkstandalone available (inside pika-iso-v2, or the host with
# grub-efi-amd64-bin).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
. "$HERE/info.sh"

LIVE_BOOT_PATH="$BUILD/LIVE_BOOT"
LIVE_BOOT_DATA_PATH="$LIVE_BOOT_PATH/data"
GRUB_TMP="$LIVE_BOOT_PATH/grub"
EFIBOOT_IMG="$LIVE_BOOT_PATH/efiboot.img"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ -s "$LIVE_BOOT_DATA_PATH/live/filesystem.squashfs" ] || { echo "no squashfs" >&2; exit 1; }
[ -d "$GRUB_TMP/EFI" ] || { echo "no grub tree" >&2; exit 1; }
[ -f "$GRUB_TMP/EFI/vmlinuz" ] || { echo "no kernel in grub tree" >&2; exit 1; }
[ -f "$GRUB_TMP/EFI/initrd" ] || { echo "no initrd in grub tree" >&2; exit 1; }
command -v grub-mkstandalone >/dev/null || { echo "grub-mkstandalone not found" >&2; exit 1; }

log "rebuilding GRUB2 ESP"
cp -f "$GRUB_DATA/grub.cfg" "$GRUB_TMP/grub.cfg"
sed -i "s#THE_NAME_OF_CURRENT_ISO_FOR_VENTOY#$ISO_IMAGE.iso#g" "$GRUB_TMP/grub.cfg"
grub-mkstandalone \
    --format=x86_64-efi \
    --output="$GRUB_TMP/EFI/BOOT/BOOTX64.EFI" \
    --modules="part_gpt part_msdos fat exfat ntfs linux normal iso9660 search search_label search_fs_uuid all_video gfxterm gfxmenu font videoinfo echo test configfile serial terminfo" \
    --locales="" \
    --themes="" \
    "boot/grub/grub.cfg=$GRUB_TMP/grub.cfg"

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
mdir -i "$EFIBOOT_IMG" ::/EFI/BOOT

log "xorriso -> ISO"
ISO_OUTPUT="$BUILD/output/$ISO_IMAGE.iso"
MD5_OUTPUT="$BUILD/output/$ISO_IMAGE.md5"
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
ls -lh "$ISO_OUTPUT"
