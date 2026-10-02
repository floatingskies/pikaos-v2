#!/usr/bin/env bash
# Regenerate the PikaOS-v2 apt repository metadata from the debs collected in
# v2/repo/pool/main.
#
# Port of the PikaOS repository-tooling contract (repo-tools/workflows'
# lib/apt-update.sh + pika-base-debian-container's gen-apt-config.sh) reduced to
# a single flat, trusted, local-only repository:
#   * Packages / Packages.gz  -- the index the live rootfs installs from
#   * Release                 -- hostable metadata (apt-ftparchive when present)
#   * pikaos-v2.list          -- the file:// source used by iso-v2/inner-build.sh
#
# Unlike upstream, no package is ever published anywhere: the index is only
# consumed from the checked-out tree or an Actions artifact.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REPO="${V2_REPO:-$ROOT/v2/repo}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ -d "$REPO/pool/main" ] || { echo "no $REPO/pool/main — build packages first" >&2; exit 1; }
cd "$REPO"

shopt -s nullglob
debs=(pool/main/*.deb)
[ "${#debs[@]}" -gt 0 ] || { echo "no debs in $REPO/pool/main" >&2; exit 1; }

log "indexing ${#debs[@]} deb(s) in pool/main"
rm -f Packages Packages.gz Release
dpkg-scanpackages --multiversion pool/main > Packages
gzip -9 -kf Packages

# A Release file is optional for a trusted file:// source but makes the tree
# directly hostable over HTTP later. Write a minimal one when apt-ftparchive is
# unavailable so downstream steps always find the file.
if command -v apt-ftparchive >/dev/null 2>&1; then
    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin="PikaOS-v2" \
        -o APT::FTPArchive::Release::Label="PikaOS v2" \
        -o APT::FTPArchive::Release::Suite="v2" \
        -o APT::FTPArchive::Release::Codename="v2" \
        -o APT::FTPArchive::Release::Architectures="amd64" \
        release . > Release
else
    {
        printf 'Origin: PikaOS-v2\nLabel: PikaOS v2\nSuite: v2\nCodename: v2\n'
        printf 'Architectures: amd64\nDate: %s\n' "$(date -Ru)"
    } > Release
fi

# The source list consumed by the ISO. The repo is bind-mounted at /opt/v2repo
# by iso-v2/inner-build.sh, so this path is the in-build location, not a mirror
# URL. It is committed so a fresh checkout is immediately usable.
cat > pikaos-v2.list <<'EOF'
# PikaOS v2 local x86-64-v2 repository.
# iso-v2/inner-build.sh bind-mounts this repo at /opt/v2repo.
deb [trusted=yes] file:/opt/v2repo ./
EOF

log "Packages: $(grep -c '^Package:' Packages) package stanza(s); pikaos-v2.list written"
