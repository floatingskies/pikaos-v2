#!/usr/bin/env bash
# Build one PikaOS package for x86-64-v2 from its official git.pika-os.com repo.
#
# Usage:
#   v2/pkg-build.sh <org>/<name>       e.g. boot-packages/booster
#   v2/pkg-build.sh local:/path/to/repo
#
# The v2 ISA is injected by copying build-config/amd64-v2.sh to
# pika-build-config.sh in the source tree before main.sh runs, exactly as the
# PikaOS CI contract does. Output debs land in v2/repo/pool/main/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${PKG_BUILDER_IMAGE:-pika-v2-builder}"
GITBASE="https://git.pika-os.com"
WORK="$HERE/work"
REPO="$HERE/repo"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ $# -ge 1 ] || { echo "usage: pkg-build.sh <org>/<name> | local:/path" >&2; exit 2; }

case "$1" in
  local:*) SRC="${1#local:}"; NAME="$(basename "$SRC")" ;;
  *)       SRC="$1";          NAME="${1##*/}" ;;
esac
# Unique work-dir key: two orgs may ship a package with the same basename.
KEY="${SRC//\//__}"

build_image() {
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then return; fi
  if [ "${PKG_BUILDER_PULL:-0}" = 1 ]; then
    log "pulling builder image $IMAGE"
    docker pull "$IMAGE" && return
    log "pull failed; falling back to a local build"
  fi
  log "building builder image $IMAGE"
  docker build -t "$IMAGE" "$HERE/builder"
}

fetch_source() {
  local dst="$WORK/$KEY"
  rm -rf "$dst"
  if [ -d "$SRC" ]; then
    log "using local source $SRC -> $dst"
    cp -a "$SRC" "$dst"
    rm -rf "$dst/.git"
  else
    log "cloning $GITBASE/$SRC.git"
    git clone --depth 1 "$GITBASE/$SRC.git" "$dst"
  fi
  cp "$HERE/build-config/amd64-v2.sh" "$dst/pika-build-config.sh"
  mkdir -p "$dst/pika-build-config"
  cp "$HERE/build-config/amd64-v2.sh" "$dst/pika-build-config/amd64-v2.sh"

  # KF5/PikaOS-only dependencies would make these packages uninstallable on a
  # KF6 sid base; rewrite them out of every control file first. See
  # v2/ci/dep-shims.tsv.
  local shimmed=0
  while IFS= read -r ctl; do
    perl "$HERE/ci/apply-dep-shims.pl" "$HERE/ci/dep-shims.tsv" "$ctl" && shimmed=1
  done < <(find "$dst" -path '*/debian/control' -type f)
  [ "$shimmed" = 1 ] && log "dep-shims applied"

  # PikaOS' changelog bot (and old upstream entries) stamp signoff trailers with
  # "GMT"/"UTC" or a short "+00"; the newer Debian sid changelog parser rejects
  # anything that is not "+HHMM"/"-HHMM" ("Could not parse timestamp ... signoff
  # date"). Normalize every trailer timezone in the tree before dh_* reads it.
  while IFS= read -r cl; do
    perl -i -pe '
      s/ GMT\s*$/ +0000/ if /^\s*-- /;
      s/ UTC\s*$/ +0000/ if /^\s*-- /;
      s/ ([+-]\d{2}):(\d{2})\s*$/ $1$2/ if /^\s*-- /;
      s/ ([+-]\d{2})\s*$/ ${1}00/ if /^\s*-- /;
    ' "$cl"
  done < <(find "$dst" -path '*/debian/changelog' -type f)
}

run_build() {
  log "building $NAME for x86-64-v2"
  docker run --rm \
    -v "$WORK/$KEY:/work" \
    -w /work \
    -e FORCE_UNSAFE_CONFIGURE=1 \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    "$IMAGE" bash -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive
      # The host owns the tree as an unprivileged user but this container runs
      # as root, so git refuses to touch /work ("detected dubious ownership").
      git config --global --add safe.directory "*"
      # Hand the tree back to the host user even if the build fails.
      trap "chown -R ${HOST_UID}:${HOST_GID} /work" EXIT
      . ./pika-build-config.sh
      echo "[v2] PIKA_BUILD_ARCH=$PIKA_BUILD_ARCH"
      echo "[v2] CFLAGS=$DEB_CFLAGS_MAINT_APPEND"
      # The builder image ships no apt lists (they are pruned to keep it slim),
      # so refresh them before main.sh runs apt-get build-dep/source.
      apt-get update
      bash ./main.sh
    '
}

collect() {
  mkdir -p "$REPO/pool/main"
  local found=0 f debs=""
  shopt -s nullglob
  for f in "$WORK/$KEY"/output/*.deb "$WORK/$KEY"/*.deb; do
    cp -f "$f" "$REPO/pool/main/"; echo "  + $(basename "$f")"
    debs+="$(basename "$f")"$'\n'; found=1
  done
  [ "$found" = 1 ] || { echo "ERROR: $NAME produced no .deb" >&2; exit 1; }
  save_stamp
}

# ---------------------------------------------------------------------------
# Build cache
#
# A package is rebuilt only when something that can change its output changed:
# the upstream commit it was built from, or the build inputs we inject (the v2
# ISA flags, the dependency shims and the script that applies them). Otherwise
# the debs already in v2/repo/pool/main are reused, which saves most of the
# ~15 minutes a full fleet rebuild costs on CI.
# ---------------------------------------------------------------------------
fingerprint() {
  local sha
  sha="$(git -C "$WORK/$KEY" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$sha" ] || sha="local-$(find "$WORK/$KEY" -type f -printf '%T@ %s %p\n' 2>/dev/null | sort | sha256sum | cut -d' ' -f1)"
  printf '%s\n' "$sha"
  sha256sum "$HERE/build-config/amd64-v2.sh" | cut -d' ' -f1
  sha256sum "$HERE/ci/dep-shims.tsv" | cut -d' ' -f1
  sha256sum "$HERE/ci/apply-dep-shims.pl" | cut -d' ' -f1
}

cache_is_current() {
  local stamp="$STAMP_DIR/$KEY.stamp"
  [ -s "$stamp" ] || return 1
  [ "$(head -4 "$stamp")" = "$FINGERPRINT" ] || return 1
  local d
  while read -r d; do
    [ -z "$d" ] && continue
    [ -s "$REPO/pool/main/$d" ] || return 1
  done < <(sed -n '5,$p' "$stamp")
  return 0
}

save_stamp() {
  mkdir -p "$STAMP_DIR"
  local d
  {
    printf '%s\n' "$FINGERPRINT"
    for d in "$REPO/pool/main"/*.deb; do
      [ -e "$d" ] && basename "$d"
    done
  } > "$STAMP_DIR/$KEY.stamp"
}

build_image
fetch_source

FINGERPRINT="$(fingerprint)"
STAMP_DIR="$REPO/.stamps"

if cache_is_current; then
  log "$NAME is up to date; reusing the cached deb(s):"
  sed -n '5,$p' "$STAMP_DIR/$KEY.stamp" | sed 's/^/  = /'
  exit 0
fi
log "$NAME needs building"

run_build
collect
log "done: $NAME"
