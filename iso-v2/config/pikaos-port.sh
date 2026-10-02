#! /bin/bash
# PikaOS v2 community port: live-session customisation. Runs inside the chroot right after the
# package install (see iso-v2/inner-build.sh).
#
# Everything here is distribution *identity*: the os-release record, the about
# logo, the apt behaviour and the KDE debloat list. It deliberately does NOT
# rename any upstream PikaOS package -- those keep their upstream names so they
# stay rebuildable from git.pika-os.com.
#
# Licensing note: the PikaOS packages installed here are upstream works under
# their own licences (mostly GPL-3.0). Rebranding the derivative does not remove
# any obligation: /usr/share/doc/pikaos/copyright keeps the upstream notices, and
# the GPL text is installed on the image. Image assets are handled separately --
# only assets with a clear GPL/CC grant are shipped (see DEBLOAT/branding below).
set -euo pipefail

DISTRO_ID="pikaos"
DISTRO_NAME="PikaOS"
DISTRO_CODENAME="pikaos"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. os-release
# ---------------------------------------------------------------------------
log "writing /etc/os-release ($DISTRO_ID)"
cat > /etc/os-release <<EOF
NAME="$DISTRO_NAME"
ID=$DISTRO_ID
ID_LIKE=debian
PRETTY_NAME="$DISTRO_NAME v2 (community port)"
VERSION_ID="2.0"
VERSION="2.0 (community port)"
VERSION_CODENAME=$DISTRO_CODENAME
HOME_URL="https://github.com/floatingskies/pikaos-v2"
SUPPORT_URL="https://github.com/floatingskies/pikaos-v2/issues"
BUG_REPORT_URL="https://github.com/floatingskies/pikaos-v2/issues"
ANSI_COLOR="1;34"
LOGO=pika-logo
EOF
# On Debian /usr/lib/os-release already points at /etc/os-release, and ln
# refuses when they are the same file -- which aborted the whole script.
[ -e /usr/lib/os-release ] || ln -sf /etc/os-release /usr/lib/os-release

# ---------------------------------------------------------------------------
# 2. about logo and default wallpaper
#
# Artwork is supplied by the distributor and staged by inner-build.sh into
# /usr/share/pikaos/branding. Only assets with a clear free licence are shipped;
# see the notices in section 5.
# ---------------------------------------------------------------------------
log "installing the about logo"
install -d /usr/share/pikaos/branding
if [ -f /usr/share/pikaos/branding/logo.png ]; then
    install -Dm0644 /usr/share/pikaos/branding/logo.png /usr/share/icons/hicolor/256x256/apps/pika-logo.png
    install -Dm0644 /usr/share/pikaos/branding/logo.png /usr/share/pixmaps/pika-logo.png
fi
if [ -f /usr/share/pikaos/branding/logo.svg ]; then
    install -Dm0644 /usr/share/pikaos/branding/logo.svg /usr/share/icons/hicolor/scalable/apps/pika-logo.svg
    install -Dm0644 /usr/share/pikaos/branding/logo.svg /usr/share/pixmaps/pika-logo.svg
fi

# KDE's About/system-info reads the distributor logo from kcm_aboutrc.
mkdir -p /etc/xdg/kcm
cat > /etc/xdg/kcm/kcm_aboutrc <<'KCMEOF'
[About]
distributorLogo=/usr/share/pixmaps/pika-logo.png
KCMEOF
for f in /etc/kdeglobals /etc/xdg/kdeglobals; do
    [ -f "$f" ] || continue
    if grep -q '^\[KDE\]' "$f"; then
        sed -i '/^\[KDE\]/a distributorLogo=/usr/share/pixmaps/pika-logo.png' "$f"
    fi
done

# ---------------------------------------------------------------------------
# 2b. wallpaper as a real KDE wallpaper package
#
# A loose .jpg in /usr/share/backgrounds is invisible to Desktop Settings, which
# only lists wallpapers under /usr/share/wallpapers/<name>/contents with a
# metadata.json. Build that layout so the mascot's wallpaper shows up in the
# chooser.
# ---------------------------------------------------------------------------
log "registering the wallpaper in the KDE collection"
mkdir -p /usr/share/wallpapers/pikaos/contents/files
for bg in /usr/share/backgrounds/woof*; do
    [ -f "$bg" ] || continue
    base="$(basename "$bg")"
    # keep the name stable and free of spaces inside the package
    clean="$(printf '%s' "$base" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
    cp -f "$bg" "/usr/share/wallpapers/pikaos/contents/files/$clean"
    MAINFILE="$clean"
    break
done
if [ -n "${MAINFILE:-}" ]; then
    cat > /usr/share/wallpapers/pikaos/contents/metadata.json <<JSONEOF
{
    "KPlugin": {
        "Id": "pikaos",
        "Name": "PikaOS",
        "PreviewImage": "thumbnails/$MAINFILE"
    },
    "X-KDE-PackageName": "PikaOS",
    "X-KDE-PackageName[pt_BR]": "PikaOS"
}
JSONEOF
    # Plasma shows this name in the wallpaper chooser.
    install -d /usr/share/wallpapers/pikaos/contents/thumbnails
    cp -f "/usr/share/wallpapers/pikaos/contents/files/$MAINFILE" \
          "/usr/share/wallpapers/pikaos/contents/thumbnails/$MAINFILE"
fi

# ---------------------------------------------------------------------------
# 2c. plymouth theme carrying the logo
#
# plymouth-theme-pika ships PikaOS artwork; this makes sure the theme uses the
# the distributor's own logo instead. plymouth can only blit a bitmap, so the
# PNG is used directly.
# ---------------------------------------------------------------------------
if [ -f /usr/share/pixmaps/pika-logo.png ] && [ -d /usr/share/plymouth ]; then
    log "installing the PikaOS plymouth theme"
    mkdir -p /usr/share/plymouth/themes/pikaos
    cp -f /usr/share/pixmaps/pika-logo.png /usr/share/plymouth/themes/pikaos/logo.png
    cat > /usr/share/plymouth/themes/pikaos/pikaos.script <<'PLEOF'
# PikaOS v2 plymouth theme: the distributor logo on the default background.
Logo.SetImage("logo.png");
Logo.SetImageProgress(0.0);

for (i = 0; i < 200; i++) {
    progress = i * 0.005;
    Logo.SetImageProgress(progress);
    refresh();
    sleep(0.02);
}

Logo.SetImageProgress(1.0);
PLEOF
    install -d /etc/plymouth
    if [ -f /etc/plymouth/plymouthd.conf ]; then
        sed -i 's/^Theme=.*/Theme=pikaos/' /etc/plymouth/plymouthd.conf
    else
        printf 'Theme=pikaos\n' > /etc/plymouth/plymouthd.conf
    fi
    command -v update-plymouth >/dev/null 2>&1 && update-plymouth --text-only 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 3. apt behaviour
#
# * keep downloaded lists (so apx/apt can work offline-ish and the live session
#   does not re-download the index on every invocation)
# * do not remove packages as a side effect of autoremove
# * let apt see the local x86-64-v2 repo with its real priority
# ---------------------------------------------------------------------------
log "apt configuration"
install -d /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99pikaos <<'EOF'
// PikaOS v2 community port live session.
APT::Install-Recommends "true";
APT::Install-Suggests "false";
APT::Get::Assume-Yes "true";
APT::Keep-Downloaded-Packages "true";
APT::Periodic::Update-Package-Lists "0";
APT::AutoRemove::RecommendsImportant "false";
Acquire::Languages "none";
EOF
# apx ships /etc/apx/apx.json; make sure its paths are valid for this root.
if [ -f /etc/apx/apx.json ]; then
    sed -i 's#"apxPath": *"[^"]*"#"apxPath": "/usr/share/apx"#' /etc/apx/apx.json
fi

# ---------------------------------------------------------------------------
# 4. KDE debloat
#
# kde-plasma-desktop drags in a lot of applications this live image does not
# need. Purge the obvious ones to keep the ISO small. Anything removed here is
# still installable from the archive; this only trims the default session.
# ---------------------------------------------------------------------------
log "debloating KDE (keeping kde-plasma-desktop: pika-kde-desktop depends on it)"
DEBLOAT="
konqueror kate kwrite kcalc kgamma khelpcenter kgpg kinfocenter
kaddressbook kmail akregator kalendar korganizer kontact ktoe
kio-extras kio-fuse kio-audiocd kio-mbox kio-dict kio-wav
kdenlive kate-minimal plasma-workspace-dev
okular konqpart gwenview spectacle kcolorchooser kimageformats-qt
kaccounts-integration kaccounts-providers
kde-spectacle kdevelop kgeany
bluedevil gnome-calculator gnome-todo
"
# shellcheck disable=SC2086
apt-get purge -y --auto-remove $DEBLOAT >/dev/null 2>&1 || \
    log "debloat: some packages were not installed, continuing"
apt-get autoremove -y >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 5. licence notices
# ---------------------------------------------------------------------------
log "licence notices"
install -d /usr/share/doc/pikaos
cat > /usr/share/doc/pikaos/copyright <<'EOF'
PikaOS v2 (community port)
=========

PikaOS v2 is a community port of PikaOS on Debian sid. It ships packages rebuilt from
git.pika-os.com under their original names and licences; rebranding the
distribution does not change those licences or remove any obligation.

PikaOS packages
---------------
PikaOS is developed by the PikaOS project (https://pika-os.com,
git.pika-os.com) and is distributed under the GNU General Public License,
version 3, unless a package states otherwise. Those copyright notices,
AUTHORS files and licence texts are retained in each package's own
/usr/share/doc/<package>/copyright and must be preserved when redistributing.

Third-party artwork
-------------------
pika-wallpapers, sound-theme-pika
  Upstream-Name: pop-fonts
  Copyright: Copyright 2016-2017 System76
  License: SIL Open Font License 1.1 (OFL-1.1)
  The OFL permits redistribution and bundling, provided the notice is kept.

papirus-colors
  Copyright: 2021 Alexey Varfolomeev; debian/* 2022 Erich Eickmeyer
  License: GPL-3

Distributor artwork
-------------------
The artwork and wallpaper shipped under /usr/share/pikaos/branding and
/usr/share/backgrounds are the distributor's own and are covered by this
project's licence. Assets from upstream whose licence does not clearly permit
redistribution are not shipped.
EOF

log "PikaOS v2 community-port customisation done"