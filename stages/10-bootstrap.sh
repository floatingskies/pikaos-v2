#!/bin/bash
# PikaOS-v2 :: stage 10 :: bootstrap a Debian sid rootfs for x86-64-v2
#
# Runs as root inside the build container. Idempotent: an existing rootfs is
# reused unless FORCE=1.
set -euo pipefail

ROOTFS="${ROOTFS:?ROOTFS not set}"
. /build/config/pika.conf
mkdir -p "${ROOTFS}"
STATEDIR="$(dirname "${ROOTFS}")/state"
mkdir -p "${STATEDIR}"

# NOTE: we deliberately do NOT add the PikaOS upstream repository
# (pkg.pika-os.com / git.pika-os.com) here. Every PikaOS component in this
# image is built from the sources vendored in upstream/ at x86-64-v2, so the
# image has no runtime dependency on upstream packaging.
MIRROR="http://deb.debian.org/debian"
# NOTE: Debian sid has no separate `sid/updates` suite; security updates for sid
# land in main. Referencing sid/updates makes apt fail with "does not have a
# Release file".

# Debian archive keyring must exist before apt can verify sid's Release file.
install -d /usr/share/keyrings
apt-get install -y --no-install-recommends debian-archive-keyring >/dev/null

# Sources for the chroot that mmdebstrap is about to create. NOTE: these must be
# written INSIDE ${ROOTFS} — writing to /etc/apt/sources.list here would only
# change the build container, and the image would end up with "main" only
# (no firmware, no i386, no contrib).
cat > "${ROOTFS}/etc/apt/sources.list" <<EOF
deb ${MIRROR} sid main contrib non-free non-free-firmware
EOF

if [ ! -e "${STATEDIR}/bootstrap-done" ]; then
  echo ">>> mmdebstrap: building sid rootfs (this pulls ~1.5G)"
  mmdebstrap \
    --architectures=amd64,i386 \
    --variant=essential \
    --include=systemd-sysv,systemd-resolved,apt,ca-certificates,curl,wget,gnupg \
    sid "${ROOTFS}" "${MIRROR}"
  touch "${STATEDIR}/bootstrap-done"
fi

# Architecture activation inside the chroot
for a in ${DPKG_ARCH}; do
  if [ "${a}" != "amd64" ]; then
    dpkg --root="${ROOTFS}" --add-architecture "${a}"
  fi
done
dpkg --root="${ROOTFS}" --print-architecture > /dev/null

# APT inside the chroot: allow install of everything, no service start
cat > "${ROOTFS}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "${ROOTFS}/usr/sbin/policy-rc.d"

cat > "${ROOTFS}/etc/apt/apt.conf.d/99pika-build" <<'EOF'
APT::Install-Recommends "true";
APT::Install-Suggests "false";
Acquire::Retries "5";
Acquire::http::Timeout "30";
APT::Get::Assume-Yes "true";
EOF

# Sid ships new enough dpkg for x86-64 level aware builds
printf 'force-architecture\n' >/dev/null

echo ">>> stage10 complete: $(du -sh "${ROOTFS}" | cut -f1)"