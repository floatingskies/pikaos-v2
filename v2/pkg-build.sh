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
  local dst="$WORK/$NAME"
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
}

run_build() {
  log "building $NAME for x86-64-v2"
  docker run --rm \
    -v "$WORK/$NAME:/work" \
    -w /work \
    -e FORCE_UNSAFE_CONFIGURE=1 \
    "$IMAGE" bash -c '
      set -e
      . ./pika-build-config.sh
      echo "[v2] PIKA_BUILD_ARCH=$PIKA_BUILD_ARCH"
      echo "[v2] CFLAGS=$DEB_CFLAGS_MAINT_APPEND"
      bash ./main.sh
    '
}

collect() {
  mkdir -p "$REPO/pool/main"
  local found=0 f
  shopt -s nullglob
  for f in "$WORK/$NAME"/output/*.deb "$WORK/$NAME"/*.deb; do
    cp -f "$f" "$REPO/pool/main/"; echo "  + $(basename "$f")"; found=1
  done
  [ "$found" = 1 ] || { echo "ERROR: $NAME produced no .deb" >&2; exit 1; }
}

build_image
fetch_source
run_build
collect
log "done: $NAME"
