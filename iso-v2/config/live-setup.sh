#! /bin/bash
# Runs INSIDE the live rootfs chroot. Sourced vars come from /root/live.env.
# Adapted from PikaOS images/live-iso-kde chroot_scripts + hooks.
set -euo pipefail
# shellcheck disable=SC1091
. /root/live.env
export DEBIAN_FRONTEND=noninteractive

echo "### live-setup: hostname / hosts"
echo "$LIVE_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
127.0.1.1	$LIVE_HOSTNAME
EOF

echo "### live-setup: locale / console"
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
cat > /etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
cat > /etc/vconsole.conf <<EOF
KEYMAP=us
FONT=Lat2-Terminus16
EOF
# booster's vconsole support looks under /usr/share/kbd/consolefonts (Arch
# layout); Debian ships them in /usr/share/consolefonts.
mkdir -p /usr/share/kbd
[ -e /usr/share/kbd/consolefonts ] || ln -s /usr/share/consolefonts /usr/share/kbd/consolefonts
[ -e /usr/share/kbd/keymaps ] || { [ -d /usr/share/keymaps ] && ln -s /usr/share/keymaps /usr/share/kbd/keymaps; }

echo "### live-setup: timezone"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

echo "### live-setup: live user"
if ! id "$LIVE_USER" >/dev/null 2>&1; then
    groupadd -g "$LIVE_UID" "$LIVE_USER" 2>/dev/null || true
    useradd -u "$LIVE_UID" -g "$LIVE_UID" -m -s /bin/bash -c "$LIVE_GECOS" "$LIVE_USER"
    passwd -d "$LIVE_USER"
fi
for g in adm cdrom sudo audio video render dip plugdev input lpadmin netdev; do
    groupadd "$g" 2>/dev/null || true
    usermod -aG "$g" "$LIVE_USER" 2>/dev/null || true
done
echo "$LIVE_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/live-$LIVE_USER"
chmod 0440 "/etc/sudoers.d/live-$LIVE_USER"

echo "### live-setup: getty autologin on tty1"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $LIVE_USER --noclear %I \$TERM
EOF

echo "### live-setup: SDDM autologin + graphical target (KDE)"
if [ -x /usr/bin/sddm ] || dpkg -s sddm >/dev/null 2>&1; then
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/10-pika-live.conf <<EOF
[Autologin]
User=$LIVE_USER
Session=plasma
Relogin=false
EOF
    systemctl enable sddm.service 2>/dev/null || true
    systemctl set-default graphical.target 2>/dev/null || true
fi
if command -v NetworkManager >/dev/null 2>&1; then
    systemctl enable NetworkManager.service 2>/dev/null || true
fi

echo "### live-setup: booster config"
cat > /etc/booster.yaml <<'EOF'
# PikaOS-v2 live: UEFI + rEFInd + booster. The Debian kernel keeps
# squashfs/overlay/iso9660 as modules, so force-include and force-load them
# for the pika-live-booster-hooks live boot path.
vconsole: true
extra_files: busybox
enable_lvm: false
universal: false
enable_hooks: true
enable_plymouth: false
modules: loop,squashfs,overlay,iso9660,sr_mod,usb_storage,uas,sd_mod,ahci,nvme,xhci_hcd,ehci_pci,ehci_hcd,uhci_hcd,ohci_hcd,hid_generic,usbhid,ext4,vfat
modules_force_load: loop,squashfs,overlay,iso9660,sr_mod,usb_storage,uas,sd_mod,ahci,nvme,hid_generic,usbhid
EOF

echo "### live-setup: regenerate initramfs (booster wrapper)"
update-initramfs -c -k all

echo "### live-setup: identity marker"
cat > /etc/pikaos-release <<EOF
PikaOS v2 (x86-64-v2 live)
ID=pikaos
ID_LIKE=debian
PRETTY_NAME="PikaOS-v2 KDE (x86-64-v2)"
VERSION_ID="4.0"
HOME_URL="https://git.pika-os.com/"
EOF

echo "### live-setup: cleanup"
apt-get clean
rm -rf /var/lib/apt/lists/*
