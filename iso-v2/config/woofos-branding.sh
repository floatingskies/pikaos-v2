#! /bin/bash
# WoofOS v2 live-session customisation. Runs inside the chroot right after the
# package install (see iso-v2/inner-build.sh).
#
# Everything here is distribution *identity*: the os-release record, the about
# logo, the apt behaviour and the KDE debloat list. It deliberately does NOT
# rename any upstream PikaOS package -- those keep their upstream names so they
# stay rebuildable from git.pika-os.com.
#
# Licensing note: the PikaOS packages installed here are upstream works under
# their own licences (mostly GPL-3.0). Rebranding the derivative does not remove
# any obligation: /usr/share/doc/woofos/copyright keeps the upstream notices, and
# the GPL text is installed on the image. Image assets are handled separately --
# only assets with a clear GPL/CC grant are shipped (see DEBLOAT/branding below).
set -euo pipefail

DISTRO_ID="woofos"
DISTRO_NAME="WoofOS"
DISTRO_CODENAME="woof"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. os-release
# ---------------------------------------------------------------------------
log "writing /etc/os-release ($DISTRO_ID)"
cat > /etc/os-release <<EOF
NAME="$DISTRO_NAME"
ID=$DISTRO_ID
ID_LIKE=debian
PRETTY_NAME="$DISTRO_NAME (PikaOS-v2 derivative)"
VERSION_ID="2.0"
VERSION="2.0 (PikaOS-v2)"
VERSION_CODENAME=$DISTRO_CODENAME
HOME_URL="https://github.com/floatingskies/pikaos-v2"
SUPPORT_URL="https://github.com/floatingskies/pikaos-v2/issues"
BUG_REPORT_URL="https://github.com/floatingskies/pikaos-v2/issues"
ANSI_COLOR="1;34"
LOGO=$DISTRO_ID-logo
EOF
ln -sf /etc/os-release /usr/lib/os-release

# ---------------------------------------------------------------------------
# 2. about logo and default wallpaper
#
# Artwork is supplied by the distributor and staged by inner-build.sh into
# /usr/share/woofos/branding. Only assets with a clear free licence are shipped;
# see the notices in section 5.
# ---------------------------------------------------------------------------
log "installing the about logo"
install -d /usr/share/woofos/branding
if [ -f /usr/share/woofos/branding/logo.png ]; then
    install -Dm0644 /usr/share/woofos/branding/logo.png /usr/share/icons/hicolor/256x256/apps/woofos-logo.png
    install -Dm0644 /usr/share/woofos/branding/logo.png /usr/share/pixmaps/woofos-logo.png
fi
if [ -f /usr/share/woofos/branding/logo.svg ]; then
    install -Dm0644 /usr/share/woofos/branding/logo.svg /usr/share/icons/hicolor/scalable/apps/woofos-logo.svg
    install -Dm0644 /usr/share/woofos/branding/logo.svg /usr/share/pixmaps/woofos-logo.svg
fi

# KDE's About/system-info reads the distributor logo from kcm_aboutrc.
mkdir -p /etc/xdg/kcm
cat > /etc/xdg/kcm/kcm_aboutrc <<'KCMEOF'
[About]
distributorLogo=/usr/share/woofos/branding/logo.png
KCMEOF
for f in /etc/kdeglobals /etc/xdg/kdeglobals; do
    [ -f "$f" ] || continue
    if grep -q '^\[KDE\]' "$f"; then
        sed -i '/^\[KDE\]/a distributorLogo=/usr/share/woofos/branding/logo.png' "$f"
    fi
done

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
cat > /etc/apt/apt.conf.d/99woofos <<'EOF'
// WoofOS v2 live session.
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
log "debloating KDE"
DEBLOAT="
konqueror kate kwrite kcalc kgamma khelpcenter kgpg kinfocenter
kaddressbook kmail akregator kalendar korganizer kontact ktoe
kio-extras kio-fuse kio-audiocd kio-mbox kio-dict kio-wav
kdenlive kate-minimal plasma-workspace-dev
okular konqpart gwenview spectacle kcolorchooser kimageformats-qt
kaccounts-integration kaccounts-providers
plasma-discover plasma-discover-backend-flatpak plasma-discover-backend-fwupd
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
install -d /usr/share/doc/woofos
cat > /usr/share/doc/woofos/copyright <<'EOF'
WoofOS v2
=========

WoofOS v2 is a Debian sid derivative. It ships packages rebuilt from
git.pika-os.com under their original names and licences; rebranding the
distribution does not change those licences or remove any obligation.

PikaOS packages
---------------
PikaOS is developed by the PikaOS project (https://pika-os.com,
git.pika-os.com) and is distributed under the GNU General Public License,
version 3, unless a package states otherwise. Those copyright notices,
AUTHORS files and licence texts are retained in each package's own
/usr/share/doc/<package>/copyright and must be preserved when redistributing.

Image assets
------------
Only assets with an explicit free licence are redistributed. The papirus icon
theme is GPL-3.0. Wallpapers and artwork are replaced by the distributor's own
branding unless their licence is known to permit reuse with attribution.
EOF

log "WoofOS customisation done"