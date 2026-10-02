#!/bin/bash
# PikaOS-v2 :: stage 50 :: desktop flavour
#   TARGET_FLAVOUR=gnome | kde
#
# Each flavour gets its own rootfs copy + squashfs, built from the shared base
# so we never rebuild the 1.5G rootfs twice.

set -euo pipefail
ROOTFS="${ROOTFS:?}"
FLAVOUR="${TARGET_FLAVOUR:?set TARGET_FLAVOUR=gnome|kde}"
. /build/config/pika.conf

BASE="$(dirname "${ROOTFS}")"
FROOT="${BASE}/rootfs-${FLAVOUR}"
STATEDIR="${BASE}/state"

case "${FLAVOUR}" in
  gnome|kde) ;;
  *) echo "unknown flavour ${FLAVOUR}"; exit 1 ;;
esac

if [ -e "${STATEDIR}/flavour-${FLAVOUR}-done" ]; then
  echo ">>> flavour ${FLAVOUR} already built"; exit 0
fi

# Copy base (cheap, hardlink-preserving) if the flavour rootfs is absent.
if [ ! -d "${FROOT}" ]; then
  echo ">>> cloning base rootfs for ${FLAVOUR}"
  rm -rf "${FROOT}"
  cp -a "${ROOTFS}" "${FROOT}"
fi

chroot_run() { chroot "${FROOT}" /usr/bin/env DEBIAN_FRONTEND=noninteractive "$@"; }
APT="apt-get -y -o DPkg::Options::=--force-confnew -o DPkg::Options::=--force-confdef"

# Same /proc requirement as stage 30: without it systemd-tmpfiles breaks every
# maintainer script and package --configure fails.
mount_cleanup() {
  umount -lf "${FROOT}/dev/pts" 2>/dev/null || true
  umount -lf "${FROOT}/dev"      2>/dev/null || true
  umount -lf "${FROOT}/sys"      2>/dev/null || true
  umount -lf "${FROOT}/proc"     2>/dev/null || true
  rm -f "${FROOT}/etc/resolv.conf"
}
trap mount_cleanup EXIT
mkdir -p "${FROOT}"/{proc,sys,dev/pts}
mount -t proc  proc "${FROOT}/proc"
mount -t sysfs sys  "${FROOT}/sys"
mount --bind /dev  "${FROOT}/dev"
mount -t devpts devpts "${FROOT}/dev/pts"
rm -f "${FROOT}/etc/resolv.conf"
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "${FROOT}/etc/resolv.conf"
chroot_run apt-get update

if [ "${FLAVOUR}" = "gnome" ]; then
  echo ">>> installing GNOME stack"
  # NOTE: apt aborts the WHOLE transaction if any one name is unknown, so the
  # list is filtered through apt-cache first.
  GNOME_PKGS="gnome-session gdm3 gnome-core gnome-shell gnome-control-center
    gnome-terminal gnome-software gnome-software-plugin-flatpak
    gir1.2-gnomedesktop-3.0 yelp adwaita-icon-theme gnome-backgrounds
    gnome-shell-extension-appindicator
    xdg-desktop-portal-gnome xdg-desktop-portal-gtk
    fonts-ubuntu xdg-user-dirs-gtk"
  RESOLVED=""
  for p in ${GNOME_PKGS}; do
    if chroot_run apt-cache show "${p}" >/dev/null 2>&1; then
      RESOLVED="${RESOLVED} ${p}"
    else
      echo "  (skip ${p}: not in this suite)"
    fi
  done
  chroot_run ${APT} install ${RESOLVED} || true

  # GDM + GNOME as the session
  systemctl_preset() { :; }
  chroot_run bash -c 'echo "gdm3" > /etc/X11/default-display-manager 2>/dev/null || true'
  ln -sf /usr/share/backgrounds/pika "${FROOT}/usr/share/backgrounds/gnome-wallpapers-pika" || true

  # GNOME dark mode default, matching PikaOS's dark-first look
  mkdir -p "${FROOT}/etc/skel/.config/dconf"
  cat > "${FROOT}/etc/dconf/profile/user" <<'EOF'
user-db:user
system-db:local
EOF
  # dconf keyfile so the live session starts in dark mode without a first boot
  mkdir -p "${FROOT}/etc/dconf/db/local.d"
  cat > "${FROOT}/etc/dconf/db/local.d/00-pika-v2" <<'EOF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='Adwaita-dark'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/pika'
EOF
  chroot_run glib-compile-schemas /etc/dconf/db/local.d || true

else
  echo ">>> installing KDE Plasma stack"
  KDE_PKGS="plasma-desktop sddm plasma-workspace plasma-workspace-dev
    kwin-x11 kwin-wayland
    dolphin konsole kate plasma-nm plasma-pa
    breeze breeze-icon-theme
    sddm-theme-breeze sddm-theme-plasma
    plasma-discover"
  RESOLVED=""
  for p in ${KDE_PKGS}; do
    if chroot_run apt-cache show "${p}" >/dev/null 2>&1; then
      RESOLVED="${RESOLVED} ${p}"
    else
      echo "  (skip ${p}: not in this suite)"
    fi
  done
  chroot_run ${APT} install ${RESOLVED} || true

  echo "plasma" > "${FROOT}/etc/X11/default-display-manager" 2>/dev/null || true

  # Plasma look-and-feel packages + the PikaOS breeze theme, from upstream
  mkdir -p "${FROOT}/usr/share/plasma/look-and-feel"
  cp -a /build/upstream/pkg-pika-kde-settings/pika-kde-settings/usr/share/plasma/look-and-feel/. \
        "${FROOT}/usr/share/plasma/look-and-feel/" 2>/dev/null || true

  mkdir -p "${FROOT}/usr/share/plasma/look-and-feel/package"
  cp -a /build/upstream/pkg-pika-kde-settings/pika-kde-settings/usr/share/plasma/look-and-feel/org.pikaos.breeze-theme \
        "${FROOT}/usr/share/plasma/look-and-feel/" 2>/dev/null || true
fi

# Both flavours share the PikaOS skel (GTK theme, dconf, qt settings)
echo ">>> applying PikaOS branding + default user session"
mkdir -p "${FROOT}/etc/skel/.config"
cp -an /build/upstream/pkg-pika-gnome-settings/pika-gnome-settings/etc/skel/. \
      "${FROOT}/etc/skel/" 2>/dev/null || true
cp -an /build/upstream/pkg-pika-kde-settings/pika-kde-settings/etc/skel/. \
      "${FROOT}/etc/skel/" 2>/dev/null || true

# Record which desktop this image is
sed -i "s/^VARIANT=.*/VARIANT=${FLAVOUR}/" "${FROOT}/etc/pika-release" 2>/dev/null || true
echo "VARIANT=${FLAVOUR}" >> "${FROOT}/etc/pika-release"

# Desktop entries from skel into the live user as well, so the running session
# already looks like PikaOS before first login completes.
#
# NOTE: copy the *contents* of skel/.config, not skel/. -> the latter would
# nest a second .config and (worse) the trailing-dot copy of a directory that
# upstream ships as a symlink has historically clobbered ownership of /usr.
LIVEHOME="${FROOT}/home/${LIVE_USER}"
mkdir -p "${LIVEHOME}/.config"
for skel in pkg-pika-gnome-settings pkg-pika-kde-settings; do
  src="/build/upstream/${skel}/${skel}/etc/skel/.config"
  [ -d "${src}" ] || continue
  # copy entries, never overwrite, never follow symlinks out of the tree
  ( cd "${src}" && find . -maxdepth 1 -mindepth 1 -print0 ) |
    while IFS= read -r -d '' e; do
      [ -e "${LIVEHOME}/.config/${e}" ] && continue
      cp -a "${src}/${e}" "${LIVEHOME}/.config/" 2>/dev/null || true
    done
done
chown -R "${LIVE_UID}:${LIVE_UID}" "${LIVEHOME}"

# System trees must be root:root. A stray non-root owner on /usr makes dpkg
# refuse to configure openssh-client ("unsafe path transition /usr/bin (owned
# by pika)"), which cascades into sshfs/ksshaskpass/kdeconnect.
echo ">>> enforcing root ownership on system trees"
for d in /usr /etc /var /bin /sbin /lib /lib64 /boot /opt /srv /root; do
  [ -e "${FROOT}${d}" ] && chown -R root:root "${FROOT}${d}" 2>/dev/null || true
done

touch "${STATEDIR}/flavour-${FLAVOUR}-done"
# /proc is still mounted here, so exclude it from the size report.
echo ">>> flavour ${FLAVOUR} complete ($(du -sh --exclude=proc --exclude=sys --exclude=dev "${FROOT}" 2>/dev/null | cut -f1))"