#!/bin/bash
# PikaOS-v2 :: stage 80 :: installer + CPU level detector
#
# Installs, into every flavour rootfs:
#   * config/pika-cpuidetect  -> /usr/bin/pika-cpuidetect
#   * config/pika-install     -> /usr/bin/pika-install  (the installer, which
#                                calls the detector before touching any disk)
#   * desktop entries so the installer is one click away in GNOME and KDE
#   * grub tooling, and an explicit removal of refind if it ever sneaks in
#     from a base package (upstream PikaOS uses rEFInd; we do not).

set -euo pipefail
ROOTFS="${ROOTFS:?}"
. /build/config/pika.conf
BASE="$(dirname "${ROOTFS}")"
STATEDIR="${BASE}/state"

if [ -e "${STATEDIR}/installer-done" ]; then echo ">>> installer already staged"; exit 0; fi

install_grub_stack() {
  local froot="$1" name="$2"
  echo ">>> ${name}: installing installer + grub stack"

  # grub tooling (refind is deliberately NOT installed)
  chroot "$froot" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get -y -o Dpkg::Options::=--force-confnew \
            -o Dpkg::Options::=--force-confdef \
    install \
      grub-pc-bin grub-efi-amd64-bin grub-common debootstrap \
      gdisk parted dosfstools rsync fdisk efibootmgr util-linux \
    >/dev/null 2>&1 || true

  # Drop any rEFInd that arrived via a dependency; we ship GRUB only.
  chroot "$froot" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get -y remove --purge refind 2>/dev/null || true

  # The detector
  install -Dm755 /build/config/pika-cpuidetect "$froot/usr/bin/pika-cpuidetect"
  # The installer
  install -Dm755 /build/config/pika-install    "$froot/usr/bin/pika-install"

  # Convenience: /sbin/pika-install for muscle memory.
  ln -sf /usr/bin/pika-install "$froot/usr/sbin/pika-install"

  echo "  detector + installer installed"
}

# desktop launchers
make_desktop_entries() {
  local froot="$1" name="$2"
  mkdir -p "$froot/usr/share/applications"

  cat > "$froot/usr/share/applications/pika-install.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Install PikaOS v2
Name[pt_BR]=Instalar PikaOS v2
Comment=Install PikaOS v2 to your disk (x86-64-v2)
Exec=pkexec /usr/bin/pika-install
Icon=drive-harddisk
Terminal=false
Categories=System;
Keywords=install;installer;setup;
EOF

  cat > "$froot/usr/share/applications/pika-compat.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CPU Compatibility Check
Comment=Show whether this machine supports x86-64-v1, -v2 or -v3
Exec=zenity --info --title="PikaOS v2 compatibility" --text="\$(/usr/bin/pika-cpuidetect | sed 's/^/  /')"
Icon=drive-harddisk
Terminal=false
Categories=System;
EOF

  echo "  desktop entries added"
}

for f in gnome kde; do
  froot="${BASE}/rootfs-${f}"
  [ -d "$froot" ] || continue
  install_grub_stack "$froot" "$f"
  make_desktop_entries "$froot" "$f"
done

touch "${STATEDIR}/installer-done"
echo ">>> stage80 complete"