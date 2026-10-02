#! /bin/bash
# Rebuild only the rEFInd ESP + ISO from an existing LIVE_BOOT tree, reusing
# data/live/filesystem.squashfs and refind/. Fast iteration replacement for a
# full inner-build.sh run. Run as root (the tree is root-owned).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
. "$HERE/info.sh"

LIVE_BOOT_PATH="$BUILD/LIVE_BOOT"
LIVE_BOOT_DATA_PATH="$LIVE_BOOT_PATH/data"
REFIND_TMP="$LIVE_BOOT_PATH/refind"
EFIBOOT_IMG="$LIVE_BOOT_PATH/efiboot.img"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ -s "$LIVE_BOOT_DATA_PATH/live/filesystem.squashfs" ] || { echo "no squashfs" >&2; exit 1; }
[ -d "$REFIND_TMP/EFI" ] || { echo "no refind tree" >&2; exit 1; }
[ -f "$REFIND_TMP/EFI/vmlinuz" ] || { echo "no kernel in refind tree" >&2; exit 1; }
[ -f "$REFIND_TMP/EFI/initrd" ] || { echo "no initrd in refind tree" >&2; exit 1; }

log "rebuilding rEFInd ESP"
sed -i "s#THE_NAME_OF_CURRENT_ISO_FOR_VENTOY#$ISO_IMAGE.iso#g" "$REFIND_TMP/refind_linux.conf" "$REFIND_TMP/EFI/boot/refind.conf"
sed -i "s#THE_LABEL_OF_CURRENT_ID#$ISO_LABEL#g"               "$REFIND_TMP/refind_linux.conf" "$REFIND_TMP/EFI/boot/refind.conf"

EFI_BOOT_IMAGE_SIZE=$(( $(du -s -B1048576 "$REFIND_TMP" | cut -f1) + 10 ))
rm -f "$EFIBOOT_IMG"
dd if=/dev/zero of="$EFIBOOT_IMG" bs=1M count="$EFI_BOOT_IMAGE_SIZE" status=none
mkfs.vfat -F 32 "$EFIBOOT_IMG" >/dev/null

(
    cd "$REFIND_TMP"
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
