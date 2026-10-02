#!/bin/bash
# PikaOS-v2 :: stage 60 :: squashfs + hybrid ISO (BIOS + UEFI)

set -euo pipefail
ROOTFS="${ROOTFS:?}"
. /build/config/pika.conf
BASE="$(dirname "${ROOTFS}")"
ISOOUT="${BASE}/iso"
STATEDIR="${BASE}/state"
KERNEL_VER_FULL="$(cat "${STATEDIR}/kernel-version" 2>/dev/null || echo "")"

# Allow restricting to a single flavour: ONLY_FLAVOURS="kde"
if [ -n "${ONLY_FLAVOURS:-}" ]; then
  FLAVOURS="${ONLY_FLAVOURS}"
  echo ">>> restricted to flavours: ${FLAVOURS}"
fi

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; R=""; N=""; fi
say() { printf '%s\n' "$*"; }
ok()  { printf '%s  OK  %s %s\n' "$G" "$N" "$*"; }
err() { printf '%sFAIL %s %s\n' "$R" "$N" "$*" >&2; }

mkdir -p "${ISOOUT}"

# --------------------------------------------------- squashfs per flavour ---
# The kernel is taken straight out of the .deb, NOT from ${FROOT}/boot.
# Reason: this stage deletes the kernel from the rootfs after copying it (to
# keep the squashfs small), so on a re-run ${FROOT}/boot/vmlinuz-* is already
# gone and the copy fails. Extracting from the immutable .deb makes this stage
# idempotent and safe to interrupt.
KDEB="$(ls "$(dirname "${ROOTFS}")"/kernel/linux-image-*-pikaos_*.deb | tail -1)"
KDIR="$(dirname "${ROOTFS}")/kdeb"
rm -rf "${KDIR}"
dpkg-deb -x "${KDEB}" "${KDIR}"
KV="$(basename "$(ls "${KDIR}/boot/vmlinuz-"* | head -1)" | sed 's/^vmlinuz-//')"

# The kernel .deb ships vmlinuz but NOT initrd.img (Debian builds the
# initramfs in the postinst via update-initramfs). We therefore take BOTH from
# the base rootfs, which stage 30 configured and where update-initramfs already
# ran. That initrd already contains live-boot's initramfs hook + modules.
BASE_BOOT="${ROOTFS}/boot"
[ -f "${BASE_BOOT}/initrd.img-${KV}" ] || { echo "FATAL: no initrd for ${KV} in ${BASE_BOOT}"; exit 1; }

for F in ${FLAVOURS}; do
  FROOT="${BASE}/rootfs-${F}"
  [ -d "${FROOT}" ] || { echo "skip ${F}: no rootfs"; continue; }

  # Kernel lives outside the squashfs (loaded by the bootloader)
  mkdir -p "${ISOOUT}/${F}/live"
  echo ">>> ${F}: kernel ${KV}"
  cp -v "${BASE_BOOT}/vmlinuz-${KV}"   "${ISOOUT}/${F}/live/vmlinuz"
  cp -v "${BASE_BOOT}/initrd.img-${KV}" "${ISOOUT}/${F}/live/initrd.img"
  for f in vmlinuz initrd.img; do
    [ -s "${ISOOUT}/${F}/live/${f}" ] || { echo "FATAL: empty ${f} for ${F}"; exit 1; }
  done

  # Strip the rootfs copy of the kernel so squashfs stays smaller
  rm -f "${FROOT}"/boot/vmlinuz-* "${FROOT}"/boot/initrd.img-* "${FROOT}"/boot/config-* \
        "${FROOT}"/boot/System.map-* "${FROOT}"/boot/*.old "${FROOT}"/boot/*.bak 2>/dev/null || true

  # Live-boot user setup: the live user owns /home, uid 1000
  mkdir -p "${FROOT}/home/${LIVE_USER}"

  echo ">>> mksquashfs ${F}"
  # Reuse an existing, complete squashfs: compressing 7G with xz takes ~20min
  # and interrupting a run leaves a truncated image behind, so only rebuild if
  # the file is missing or obviously incomplete.
  # Compression is zstd, NOT xz. Our kernel config has CONFIG_SQUASHFS_ZSTD=y
  # but deliberately no CONFIG_SQUASHFS_XZ, and live-boot then fails with:
  #   Can not mount /dev/loop0 (...filesystem.squashfs)
  # zstd is also dramatically faster to compress (~5x) at a comparable ratio,
  # which matters because this runs on every build.
  # -Xbcj x86 is xz/gzip-only, so it is not used with zstd.
  SQCOMP="zstd"
  SQ="${ISOOUT}/${F}/live/filesystem.squashfs"
  NEED_SQ=1
  if [ -s "${SQ}" ]; then
    # Reuse only if it was built with the SAME compression. Otherwise we would
    # silently ship an image the kernel cannot mount.
    prev="$(cat "${SQ}.comp" 2>/dev/null || echo none)"
    if [ "${prev}" != "${SQCOMP}" ]; then
      echo "    existing squashfs was built with '${prev}', need '${SQCOMP}'; rebuilding"
    else
      src_kb="$(du -sk --exclude=proc --exclude=sys --exclude=dev "${FROOT}" 2>/dev/null | cut -f1)"
      sq_kb="$(du -k "${SQ}" | cut -f1)"
      if [ "${sq_kb}" -gt 200000 ]; then
        NEED_SQ=0
        echo "    reusing existing squashfs (${sq_kb}K, source ${src_kb}K)"
      else
        echo "    existing squashfs looks truncated (${sq_kb}K); rebuilding"
      fi
    fi
  fi
  if [ "${NEED_SQ}" = 1 ]; then
    rm -f "${SQ}"
    mksquashfs "${FROOT}" "${SQ}" \
      -comp "${SQCOMP}" -Xcompression-level 19 -b 1048576 \
      -noappend -no-progress -all-root 2>&1 | tail -2
    printf '%s' "${SQCOMP}" > "${SQ}.comp"
  fi

  # The squashfs is what actually ships. Verify the components we promised
  # are inside it: a stale squashfs built before a later stage silently drops
  # them (that is how pika-cpuidetect/pika-install went missing once).
  # Build the listing ONCE -- unsquashfs -l on a 3G image is not cheap.
  echo ">>> verifying payload of ${SQ}"
  SQLIST="$(mktemp)"
  if ! unsquashfs -l "${SQ}" > "${SQLIST}" 2>/dev/null; then
    err "cannot read squashfs ${SQ}: it is corrupt or truncated"
    rm -f "${SQLIST}"
    exit 1
  fi

  missing_files=""
  for f in usr/bin/pikman usr/bin/pika-welcome usr/bin/pika-cpuidetect \
           usr/bin/pika-install usr/sbin/grub-install usr/share/backgrounds/pika; do
    grep -qF "squashfs-root/${f}" "${SQLIST}" || missing_files="${missing_files} ${f}"
  done
  if [ -n "${missing_files}" ]; then
    err "squashfs for ${F} is missing:${missing_files}"
    echo "    It is stale: delete ${SQ} and re-run this stage." >&2
    rm -f "${SQLIST}"
    exit 1
  fi
  # rEFInd must never ship.
  if grep -q refind "${SQLIST}"; then
    err "rEFInd present in the ${F} squashfs; bootloader must be GRUB only"
    rm -f "${SQLIST}"
    exit 1
  fi
  rm -f "${SQLIST}"
  ok "payload verified (pikman, pika-welcome, detector, installer, grub; no rEFInd)"
done

# ------------------------------------------------------------ boot files ----
for F in ${FLAVOURS}; do
  D="${ISOOUT}/${F}"
  [ -d "${D}/live" ] || continue

  # --- EFI: grub
  mkdir -p "${D}/boot/grub"
  cat > "${D}/boot/grub/grub.cfg" <<EOF
set timeout=10
menuentry "PikaOS v2 (${CODENAME}) ${F^^} [live]" {
  linux /live/vmlinuz boot=live components console=ttyS0 console=tty0 quiet splash toram
  initrd /live/initrd.img
}
menuentry "PikaOS v2 ${F^^} (safe graphics)" {
  linux /live/vmlinuz boot=live components console=ttyS0 console=tty0 nomodeset nosplash
  initrd /live/initrd.img
}
menuentry "PikaOS v2 ${F^^} (RAM disk)" {
  linux /live/vmlinuz boot=live components console=ttyS0 console=tty0 toram mem=2G
  initrd /live/initrd.img
}
EOF
  # EFI image for the El Torito UEFI boot entry. Debian ships it as
  # grub-efi-amd64-bin under /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi;
  # renaming it to BOOTX64.EFI is the removable-media convention.
  mkdir -p "${D}/boot/grub/x86_64-efi"
  cp /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi "${D}/boot/grub/x86_64-efi/BOOTX64.EFI"
  [ -s "${D}/boot/grub/x86_64-efi/BOOTX64.EFI" ] || { echo "FATAL: no BOOTX64.EFI"; exit 1; }

  # Also expose the standard ESP tree at the ISO root. xorriso warns without it
  # and, more importantly, this is what makes the ISO bootable when dd-ed to a
  # USB stick on Windows, where firmware looks for /EFI/BOOT/BOOTX64.EFI.
  mkdir -p "${D}/EFI/BOOT"
  cp "${D}/boot/grub/x86_64-efi/BOOTX64.EFI" "${D}/EFI/BOOT/BOOTX64.EFI"

  # --- BIOS: isolinux
  mkdir -p "${D}/isolinux"
  cat > "${D}/isolinux/isolinux.cfg" <<EOF
UI menu.c32
PROMPT 0
TIMEOUT 100
MENU TITLE PikaOS v2 (${CODENAME}) ${F^^}
LABEL live
  MENU LABEL PikaOS v2 ${F^^} [live]
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components console=ttyS0 console=tty0 quiet splash toram
LABEL safe
  MENU LABEL PikaOS v2 ${F^^} (safe graphics)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components console=ttyS0 console=tty0 nomodeset nosplash
LABEL hd
  MENU LABEL Boot from local disk
  LOCALBOOT 0x80
EOF
  # syslinux 6.x modules that isolinux.cfg loads. `UI menu.c32` needs
  # menu.c32 present or ISOLINUX dies with "Disk error 01".
  #
  # Debian 6.04 moved these out of /usr/lib/ISOLINUX into the syslinux
  # package's per-architecture module directories:
  #   menu.c32      /usr/lib/syslinux/modules/bios/menu.c32
  #   libcom32.c32  /usr/lib/syslinux/modules/bios/libcom32.c32
  # and menu.c32 in turn needs libutil.c32 next to it.
  BIOSMODS=/usr/lib/syslinux/modules/bios
  for f in menu.c32 ldlinux.c32 libutil.c32 libcom32.c32 libmenu.c32; do
    if [ -f "${BIOSMODS}/${f}" ]; then
      cp "${BIOSMODS}/${f}" "${D}/isolinux/"
    elif [ -f "/usr/lib/ISOLINUX/${f}" ]; then
      cp "/usr/lib/ISOLINUX/${f}" "${D}/isolinux/"
    else
      echo "FATAL: missing syslinux module ${f}" >&2
      exit 1
    fi
  done
  [ -s "${D}/isolinux/menu.c32" ] || { echo "FATAL: menu.c32 not copied" >&2; exit 1; }

  # Keep a copy at the ISO root too: some BIOS paths look for /isolinux.cfg.
  cp "${D}/isolinux/isolinux.cfg" "${D}/isolinux.cfg" 2>/dev/null || true

  # Debian ships isolinux.bin as a raw 38K loader. Do NOT pad it by hand:
  # libisofs rejects anything that is not a standard El Torito size, and
  # hand-padding produced an image that booted to
  #   "ISOLINUX 6.04 ... Disk error 01"
  # The canonical invocation is -boot-load-size 4 -boot-info-table, which lets
  # libisofs build and patch the boot image itself.
  cp /usr/lib/ISOLINUX/isolinux.bin "${D}/isolinux/isolinux.bin"

  # --- build the hybrid ISO (BIOS via isolinux, UEFI via GRUB EFI image)
  OUTISO="${BASE}/pikaos-v2-${F}-${ISO_TAG}.iso"
  echo ">>> xorriso ${OUTISO}"
  rm -f "${OUTISO}"

  # xorriso invocation follows upstream PikaOS iso/mk/iso.mk (the non-GRUB_BIOS
  # branch) so the result matches what PikaOS ships:
  #   -J -r                          Joliet + Rock Ridge (Unix perms)
  #   -isohybrid-mbr + -isohybrid-gpt-basdat
  #                                  makes the ISO dd-able to a USB stick and
  #                                  bootable on UEFI firmware from USB
  #   -b/-c + -no-emul-boot -boot-load-size 4 -boot-info-table
  #                                  let libisofs build the boot image itself.
  #                                  Hand-padding isolinux.bin produces
  #                                  "ISOLINUX 6.04 ... Disk error 01".
  #   --volume_date all_file_dates   reproducible timestamps
  ISO_EPOCH="${SOURCE_DATE_EPOCH:-$(date -d '2026-01-01' +%s)}"
  xorriso -as mkisofs \
    -J -r -iso-level 3 -full-iso9660-filenames \
    -volid "PIKAV2${F^^}" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -c isolinux/boot.cat -b isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e boot/grub/x86_64-efi/BOOTX64.EFI -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "${OUTISO}" "${D}" \
    -- -volume_date all_file_dates ="${ISO_EPOCH}"

  [ -s "${OUTISO}" ] || { echo "FATAL: xorriso produced nothing"; exit 1; }
  # Users want to verify a download; upstream ships SHA256SUMS for this.
  ( cd "$(dirname "${OUTISO}")" && sha256sum "$(basename "${OUTISO}")" \
      > "$(basename "${OUTISO}").sha256" )
  ls -lh "${OUTISO}"
done

touch "${STATEDIR}/iso-done"
echo ">>> ISOs in ${ISOOUT}"