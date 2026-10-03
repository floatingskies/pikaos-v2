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

# Container engine. CI has docker; a local host may only have podman, and the
# original hardcoded `docker` calls died with "command not found" there before
# touching a single package. Resolve once, honour $CONTAINER_ENGINE.
if [ -n "${CONTAINER_ENGINE:-}" ]; then
  ENGINE="$CONTAINER_ENGINE"
else
  ENGINE=""
  for cand in docker podman; do
    if command -v "$cand" >/dev/null 2>&1; then ENGINE="$cand"; break; fi
  done
fi
[ -n "$ENGINE" ] || { echo "error: no container runtime; install docker or podman, or set CONTAINER_ENGINE" >&2; exit 2; }

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ $# -ge 1 ] || { echo "usage: pkg-build.sh <org>/<name> | local:/path" >&2; exit 2; }

case "$1" in
  local:*) SRC="${1#local:}"; NAME="$(basename "$SRC")" ;;
  *)       SRC="$1";          NAME="${1##*/}" ;;
esac
# Unique work-dir key: two orgs may ship a package with the same basename.
KEY="${SRC//\//__}"

build_image() {
  if $ENGINE image inspect "$IMAGE" >/dev/null 2>&1; then return; fi
  if [ "${PKG_BUILDER_PULL:-0}" = 1 ]; then
    log "pulling builder image $IMAGE"
    $ENGINE pull "$IMAGE" && return
    log "pull failed; falling back to a local build"
  fi
  log "building builder image $IMAGE with $ENGINE"
  $ENGINE build -t "$IMAGE" "$HERE/builder"
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

  # Defects in the upstream source itself, as opposed to the ISA level
  # (isa-shims.txt) or the maintainer scripts (script-shims.tsv). Applied to the
  # whole tree because these recipes copy themselves into a subdirectory before
  # building, so the file being fixed may be at src/main.rs or <name>/src/main.rs
  # depending on how far main.sh got.
  if [ -s "$HERE/ci/source-shims.tsv" ]; then
    perl "$HERE/ci/apply-source-shims.pl" "$HERE/ci/source-shims.tsv" "$dst" || exit 1
  fi

  # The other half of the dep-shim job. Dropping a dependency also removes
  # whatever that package created on disk, and a maintainer script that walks
  # the removed path now fails under `set -e`, leaving the package
  # half-configured. See v2/ci/script-shims.tsv.
  if [ -s "$HERE/ci/script-shims.tsv" ]; then
    local scripts_found=0
    while IFS= read -r ms; do
      perl "$HERE/ci/apply-script-shims.pl" "$HERE/ci/script-shims.tsv" "$ms" || exit 1
      scripts_found=1
    done < <(find "$dst" -path '*/debian/*' -type f \( \
                -name preinst -o -name postinst -o -name prerm -o -name postrm \
                -o -name config -o -name templates \) 2>/dev/null)
    [ "$scripts_found" = 1 ] && log "script-shims checked"
  fi

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

  # Some PikaOS repos hardcode an x86-64 level in a place the injected
  # build-config cannot reach, because they never read DEB_CFLAGS_MAINT_APPEND:
  #   otter-zenith/debian/rules  -Dcpu=x86_64_v3   (5x, every Zig build)
  #   general-packages/zig       ZIG_TARGET_MCPU x86_64_v3 (the toolchain itself)
  #   kernel-*/scripts/config.sh --set-val X86_64_VERSION 3
  # Left alone, those emit v3 objects that SIGILL on Ivy Bridge no matter what
  # amd64-v2.sh says. Rewrite them, and fold the result into the build
  # fingerprint so a change here invalidates the cached debs.
  if [ -s "$HERE/ci/isa-shims.txt" ]; then
    local isa_fixed=0
    # A file whose last line lacks a trailing newline loses that line to
    # `read`, which would silently skip a shim (and ship a v3 kernel). Assert
    # the newline and fail loudly rather than under-apply the ISA.
    if [ -n "$(tail -c 1 "$HERE/ci/isa-shims.txt")" ]; then
      echo "ERROR: $HERE/ci/isa-shims.txt has no trailing newline; the last shim would be silently dropped" >&2
      exit 1
    fi
    while IFS= read -r line; do
      case "$line" in ''|\#*) continue ;; esac
      local from="${line%%|*}"; local to="${line#*|}"
      case "$line" in *'|'*) ;; *) echo "ERROR: malformed isa-shim line: $line" >&2; exit 1 ;; esac
      local hits
      hits="$(grep -rlF -- "$from" "$dst" 2>/dev/null || true)"
      [ -n "$hits" ] || continue
      printf '%s\n' "$hits" | while IFS= read -r f; do
        perl -i -pe "s/\Q$from\E/$to/g" "$f"
      done
      isa_fixed=1
      log "isa-shim: '$from' -> '$to' in $(printf '%s\n' "$hits" | wc -l) file(s)"
    done < "$HERE/ci/isa-shims.txt"
    [ "$isa_fixed" = 1 ] || log "isa-shims: nothing to rewrite in $NAME"
  fi
}

run_build() {
  log "building $NAME for x86-64-v2"
  $ENGINE run --rm \
    -v "$WORK/$KEY:/work" \
    -w /work \
    -e FORCE_UNSAFE_CONFIGURE=1 \
    -e PIKA_JOBS="${PKG_JOBS:-}" \
    "$IMAGE" bash -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive
      # The host owns the tree as an unprivileged user but this container runs
      # as root, so git refuses to touch /work ("detected dubious ownership").
      git config --global --add safe.directory "*"
      # NOTE: no `trap chown` back to the host user here, and that is deliberate.
      # Under rootless podman the container root is an unprivileged subuid, so a
      # chown to $HOST_UID inside the container does not land on the host owner:
      # the tree comes back owned by a subuid and every later `rm -rf` of the
      # work tree fails with "Permission denied" across thousands of files. The
      # build-fleet.sh caller (and the CI runner) reclaim ownership from the
      # host side with `podman unshare chown`, where the uid mapping is the
      # other way round.
      # The kernel packages do not go through pika-build-config.sh at all (they
      # drive their own scripts/ and a .config), so only source it when present.
      if [ -f ./pika-build-config.sh ]; then
        . ./pika-build-config.sh
        echo "[v2] PIKA_BUILD_ARCH=$PIKA_BUILD_ARCH"
        echo "[v2] CFLAGS=$DEB_CFLAGS_MAINT_APPEND"
      else
        echo "[v2] no pika-build-config.sh; building on upstream defaults"
      fi
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
  sha256sum "$HERE/ci/script-shims.tsv" | cut -d' ' -f1
  sha256sum "$HERE/ci/apply-script-shims.pl" | cut -d' ' -f1
  sha256sum "$HERE/ci/source-shims.tsv" | cut -d' ' -f1
  sha256sum "$HERE/ci/apply-source-shims.pl" | cut -d' ' -f1
  # The v3->v2 hardcode rewrites change the build result, so they are part of
  # the identity of a cached deb just like the flags themselves.
  sha256sum "$HERE/ci/isa-shims.txt" | cut -d' ' -f1
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

# Give the tree back to the host user. Under rootless podman the container's
# root is an unprivileged subuid, so everything the build wrote into /work is
# owned by a uid this account does not own -- which makes `rm -rf` of the work
# tree fail with "Permission denied" on the next run, and makes a re-clone
# impossible. Reclaiming from the host side (inside `podman unshare`, where the
# mapping is the other way round) is the only thing that works.
#
# A no-op under docker, where the container root really is uid 0 and bind
# mounts keep the host's ownership.
if [ "$ENGINE" = podman ]; then
  podman unshare chown -R "$(id -u):$(id -g)" "$WORK/$KEY" 2>/dev/null || true
fi

collect
log "done: $NAME"
