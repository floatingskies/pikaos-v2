#!/usr/bin/env bash
# Build a PikaOS kernel for x86-64-v2.
#
# Usage:
#   v2/kernels/build-kernel.sh linux-pikaos-7.2
#   v2/kernels/build-kernel.sh linux-pikaos-6.18
#   PIKA_KERNEL_JOBS=8 v2/kernels/build-kernel.sh linux-pikaos-7.2
#
# The PikaOS kernel repos (git.pika-os.com/kernel-packages/linux-pikaos-*) are
# used as-is: their patch series, their .config, their debian packaging. This
# script does NOT fork them. It fetches the recipe, retargets the ISA to v2, and
# builds -- the same relationship v2/pkg-build.sh has with the rest of the fleet.
#
# Why kernels need their own script rather than going through pkg-build.sh:
#   * they never read pika-build-config.sh, so DEB_CFLAGS_MAINT_APPEND does not
#     reach them; the ISA is a Kconfig int instead (see below)
#   * they need clang + lld, which the package builder image does not carry
#   * they need ~15G of disk and an hour of CPU, so the job count has to follow
#     the host rather than a hardcoded -j32
#
# ---------------------------------------------------------------------------
# The ISA retarget, which is the whole point of this script
# ---------------------------------------------------------------------------
# PikaOS's own 7.2 and 6.18 config.sh both run
#
#     scripts/config -e GENERIC_CPU --set-val X86_64_VERSION 3
#
# CONFIG_X86_64_VERSION is an int (range 1..4) defined by CachyOS's
# 0001-cachyos-base-all.patch, and arch/x86/Makefile turns it into
#
#     KBUILD_CFLAGS    += -march=x86-64-v$(CONFIG_X86_64_VERSION)
#     KBUILD_RUSTFLAGS += -Ctarget-cpu=x86-64-v$(CONFIG_X86_64_VERSION)
#
# so 3 means -march=x86-64-v3, which needs AVX2/FMA/BMI -- none of which an
# Ivy Bridge i5-3550 has. We set 2. That is the same change as the userspace
# amd64-v2.sh, expressed the way the kernel expresses it, and it is applied to
# the fetched tree rather than to a vendored copy so it cannot drift from
# upstream silently.
#
# Note the shipped .config in these repos says CONFIG_X86_64_VERSION=1
# (baseline) because config.sh overrides it at build time. Reading the .config
# alone would tell you these kernels are v1; they are not.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2DIR="$(cd "$HERE/.." && pwd)"
GITBASE="${PIKA_GITBASE:-https://git.pika-os.com}"
WORK="${PIKA_KERNEL_WORK:-$V2DIR/work/kernels}"
OUT="${PIKA_KERNEL_OUT:-$V2DIR/repo/pool/main}"

# The package builder image carries the Debian packaging toolchain but not
# clang/lld, which these kernels require (build.sh drives LLVM=1). Debian's
# clang is 21, so the kernels are built outside unless the caller points this
# somewhere with a suitable toolchain.
CC_IMAGE="${PIKA_KERNEL_CC_IMAGE:-debian:sid}"
# `patch` is deliberately here and not assumed: the kernel build is driven
# through `patch -Np1` from the recipe's series, and debian:sid does not ship
# patch(1) (it is in the `patch` package, which a minimal image lacks). Without
# it the first patch fails and, because the failure looks like a bad patch,
# sends you off diffing hunks that are actually fine.
CC_PACKAGES="${PIKA_KERNEL_CC_PACKAGES:-make patch bc bison flex libssl-dev libelf-dev kmod rsync perl cpio xz-utils zstd gzip tar wget ca-certificates clang lld llvm dwarves python3}"

if [ -n "${CONTAINER_ENGINE:-}" ]; then
  ENGINE="$CONTAINER_ENGINE"
else
  ENGINE=""
  for c in docker podman; do
    command -v "$c" >/dev/null 2>&1 && { ENGINE="$c"; break; }
  done
fi
[ -n "$ENGINE" ] || { echo "error: no container runtime (docker or podman)" >&2; exit 2; }

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ $# -eq 1 ] || { echo "usage: build-kernel.sh <linux-pikaos-X.Y>" >&2; exit 2; }
NAME="$1"

# Only the two LTS lines this project targets. Everything else in
# kernel-packages is either superseded or is build tooling (scx, templates).
case "$NAME" in
  linux-pikaos-7.2|linux-pikaos-6.18|linux-pikaos-6.12.10) ;;
  *) echo "error: '$NAME' is not a target kernel; see the list in v2/ci/packages.tsv" >&2; exit 2 ;;
esac

# -j: PikaOS hardcodes -j32 in build.sh. On any host smaller than a 32-core
# build rig that is a memory explosion, not a speedup, and this one has 14G.
# Default to the host's cores, overridable for a big builder.
NPROC="$(nproc)"
JOBS="${PIKA_KERNEL_JOBS:-$NPROC}"
log "using -j$JOBS (host has $NPROC cores)"

SRC="$WORK/$NAME"
KVER=""
if [ -d "$SRC/patches" ]; then
  KVER="$(cat "$SRC/VERSION")"
  log "$NAME: using the recipe already in $SRC (kernel $KVER)"
else
  # The recipes are small (patches + one .config, well under a megabyte); fetch
  # them if this is a fresh tree.
  log "fetching the $NAME recipe from $GITBASE"
  mkdir -p "$WORK"
  rm -rf "$SRC"
  git clone --depth 1 -q "$GITBASE/kernel-packages/$NAME.git" "$SRC"
  KVER="$(cat "$SRC/VERSION")"
  log "$NAME: kernel $KVER"
fi

# ---------------------------------------------------------------------------
# 1. Source acquisition
#
# PikaOS source.sh builds the kernel.org URL with
#   v"$(echo VERSION | cut -f1 -d".")"
# which turns 6.18.8 into "6" and requests /pub/linux/kernel/v6/linux-6.18.8.tar.xz
# -- a path that does not exist (404). The real layout is /v6.x/ for the 6.x
# series. So 6.18 (and 6.12) cannot fetch its own source as shipped; we fetch
# it here with the corrected path.
#
# 7.2 instead takes a CachyOS tarball, which exists, and needs no fix.
# ---------------------------------------------------------------------------
fetch_source() {
  local tarball tree
  case "$NAME" in
    linux-pikaos-7.2)
      url="https://github.com/CachyOS/linux/releases/download/cachyos-$KVER-1/cachyos-$KVER-1.tar.gz"
      tarball="cachyos-$KVER-1.tar.gz"
      tree="cachyos-$KVER-1"
      ;;
    *)
      # "v6.x", not "v6" and not "v6.18.x": kernel.org keeps one directory per
      # major series, not per minor. Upstream PikaOS builds
      # v"$(echo VERSION | cut -f1 -d.)" which is "v6" and 404s. All three forms
      # were checked against cdn.kernel.org; only v6.x resolves.
      url="https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz"
      tarball="linux-$KVER.tar.xz"
      tree="linux-$KVER"
      ;;
  esac
  # Do it in a container: the host has no wget guarantee, and the fetch is the
  # one step that needs the network, which is exactly what the container gives
  # us a boundary for.
  log "fetching kernel source $KVER ($url)"
  $ENGINE run --rm -v "$SRC:/work" -w /work "$CC_IMAGE" bash -c "
    set -e
    apt-get update -qq >/dev/null
    apt-get install -y -qq wget ca-certificates >/dev/null
    wget -nv -O '$tarball' '$url'
    tar -xf '$tarball'
  "
  [ -d "$SRC/$tree" ] || { echo "error: $tree missing after fetch" >&2; exit 1; }
}

cd "$SRC"
if [ ! -d "linux-$KVER" ] && [ ! -d "cachyos-$KVER-1" ]; then
  fetch_source
fi

# From here on the build runs inside a container with clang/lld, because
# X86_64_VERSION's `depends on (CC_IS_GCC && ...) || (CC_IS_CLANG && ...)`
# is evaluated by the compiler that is actually driving the build, and the host
# does not have one.
TREE=""
for cand in "cachyos-$KVER-1" "linux-$KVER"; do
  [ -d "$SRC/$cand" ] && { TREE="$cand"; break; }
done
[ -n "$TREE" ] || { echo "error: no extracted kernel tree under $SRC" >&2; exit 1; }
log "source tree: $TREE"

# The recipe (VERSION, config, patches/, scripts/) lives beside the extracted
# tree, not inside it: upstream's own main.sh runs scripts/source.sh, which
# untars the kernel and cd's into it, and the later steps source ../scripts/.
#
# The container, though, is mounted at the tree, so from inside it the recipe is
# reachable only through explicit paths. Give the container those paths via
# absolute bind mounts of the individual recipe entries rather than trying to
# make the tree look like the recipe:
#
#   * NOT symlinks -- the kernel tree has a real scripts/ directory, so a
#     `scripts -> ../scripts` link cannot be created, and creating one for the
#     other entries produces exactly the failure seen here: a dangling link
#     where `scripts/config.sh` is expected, which reads like a missing recipe
#     rather than a mounting mistake.
#   * the recipe directory is bind mounted read-only at /recipe, which is
#     unambiguous. Read-only matters: the ISA retarget below has to write to a
#     private copy, and a writable mount would let it edit the checked-out
#     recipe that the next run starts from.
log "recipe will be mounted at /recipe from $SRC"

# The build runs as container root because it has to apt-get a compiler, but
# rootless podman maps that root to an unprivileged subuid (100999 here), so
# everything written into /work comes back owned by a uid the host user does not
# own -- which makes the extracted tree undeletable from the host and has to be
# cleaned up with `podman unshare rm`. Reclaim ownership after the run instead
# of trying to chown from inside, where the mapping works the other way.
$ENGINE run --rm \
  -v "$SRC:/work" -v "$SRC:/recipe:ro" -w "/work/$TREE" \
  -e KVER="$KVER" -e JOBS="$JOBS" -e PIKA_OUT="$OUT" \
  "$CC_IMAGE" bash -ceu '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    # shellcheck disable=SC2086
    apt-get install -y -qq '"$CC_PACKAGES"' >/dev/null

    # ---- patches, exactly the series upstream lists, in order ----
    #
    # Upstream patch.sh uses `patch ... || bash -c "echo ..."`, whose subshell
    # swallows the failure: a patch that does not apply is skipped in silence
    # and you get an unpatched kernel wearing a -pikaos version string. Hard
    # fail instead.
    #
    # Runs from the tree root, where patches/ and scripts/ are symlinks to the
    # recipe that sits beside the tree, so paths resolve as the recipe intends.
    total=$(grep -cv "^[[:space:]]*$" /recipe/patches/series)
    n=0
    while IFS= read -r p; do
      case "$p" in ""|\#*) continue ;; esac
      n=$((n + 1))
      printf "  %2d/%s %s\n" "$n" "$total" "$p"
      patch -Np1 -i "/recipe/patches/$p" || {
        echo "error: patch $p failed to apply to ${KVER}" >&2
        exit 2
      }
    done < /recipe/patches/series
    echo "applied $n patch(es)"

    # ---- the ISA retarget: x86-64-v3 -> x86-64-v2 ----
    #
    # PikaOS config.sh runs
    #   scripts/config -e GENERIC_CPU --set-val X86_64_VERSION 3
    # and arch/x86/Makefile turns that int into
    #   KBUILD_CFLAGS += -march=x86-64-v$(CONFIG_X86_64_VERSION)
    # so 3 is v3 (AVX2/FMA/BMI) and 2 is what an Ivy Bridge can run.
    #
    # /recipe is mounted read-only, which is what forces the copy: the retarget
    # has to land on a private copy of the recipe that this run owns, not on the
    # checked-out one that the next run starts from. Sourcing the pristine file
    # would silently build v3 while every check below still passed.
    cp /recipe/scripts/config.sh ./pika-config.sh
    if ! grep -q "X86_64_VERSION 3" ./pika-config.sh; then
      echo "error: the recipe no longer sets X86_64_VERSION 3." >&2
      echo "       Upstream changed how the kernel picks its ISA level, so this" >&2
      echo "       retarget is wrong now. Refusing to build." >&2
      exit 1
    fi
    perl -i -pe "s/--set-val X86_64_VERSION 3/--set-val X86_64_VERSION 2/" ./pika-config.sh
    grep -n X86_64_VERSION ./pika-config.sh

    # The Kconfig int only becomes a compiler flag through this Makefile
    # conditional. If it stops existing the value is inert and the kernel would
    # silently build at -march=x86-64 baseline.
    grep -q "march=x86-64-v\$(CONFIG_X86_64_VERSION)" arch/x86/Makefile || {
      echo "error: arch/x86/Makefile no longer derives -march from CONFIG_X86_64_VERSION" >&2
      exit 1
    }

    # ---- config ----
    # The recipe's own .config, verbatim, then the retargeted config.sh on top.
    cp /recipe/config .config
    make prepare
    . ./pika-config.sh

    grep -q "^CONFIG_X86_64_VERSION=2$" .config || {
      echo "error: .config has $(grep -oE "^CONFIG_X86_64_VERSION=[0-9]+" .config || echo unset), expected 2" >&2
      exit 1
    }
    ! grep -q "^CONFIG_X86_NATIVE_CPU=y" .config || {
      echo "error: CONFIG_X86_NATIVE_CPU=y would build -march=native" >&2
      exit 1
    }
    echo "CONFIG_X86_64_VERSION=2 in .config"

    # ---- the proof: the -march the compiler actually gets ----
    #
    # Everything above is inference about how the Makefile will read the int.
    # This reads the compiler command line. Verified sensitive to the value:
    # reports -march=x86-64-v2 at 2 and -march=x86-64-v3 at 3.
    probe="$(make V=1 arch/x86/lib.o 2>&1 | grep -m1 -oE "\-march=[a-z0-9_.+-]+" || true)"
    echo "compiler received: ${probe:-<unknown>}"
    [ "$probe" = "-march=x86-64-v2" ] || {
      echo "error: compiler invoked with ${probe:-<unknown>}, not -march=x86-64-v2" >&2
      exit 1
    }

    # ---- build ----
    #
    # LTO is on (config.sh enables it) and 0001-flags.patch adds --lto-O3 with
    # --thinlto-jobs=16 hardcoded. ThinLTO at 16 concurrent jobs wants far more
    # RAM than a small builder has, so pin it to our own job count.
    sed -i "s/--thinlto-jobs=[0-9]*/--thinlto-jobs=${JOBS}/" Makefile
    make LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld \
         -j"${JOBS}" bindeb-pkg \
         LOCALVERSION=-pikaos-v2 \
         KDEB_PKGVERSION="$(make kernelversion)-101pika1"

    # ---- collect ----
    mkdir -p "${PIKA_OUT}"
    found=0
    for f in ../*.deb; do
      case "$f" in *linux-libc*) continue ;; esac   # headers-only meta
      [ -e "$f" ] || continue
      cp -f "$f" "${PIKA_OUT}/"
      echo "  + $(basename "$f")"
      found=1
    done
    [ "$found" = 1 ] || { echo "error: build produced no debs" >&2; exit 1; }
    echo "OK"
  ' || { rc=$?; echo "kernel build failed (rc=$rc)" >&2; exit $rc; }

# Give the tree back to the host user. Rootless podman wrote it as an
# unprivileged subuid (100999 here); without this the next run's `rm -rf`, and
# the recipe re-clone, fail with permission errors across ~80k files. Note this
# is why the previous revision had to be deleted with `podman unshare rm`.
if [ "$ENGINE" = podman ]; then
  log "restoring ownership of $SRC to $(id -u):$(id -g)"
  podman unshare chown -R "$(id -u):$(id -g)" "$SRC" 2>/dev/null || true
fi

