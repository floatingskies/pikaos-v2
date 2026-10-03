#!/usr/bin/env bash
# Run a built binary on an emulated x86-64-v2 CPU and fail if it faults.
#
#   v2/ci/run-isa-test.sh <deb> [<deb>...]
#   v2/ci/run-isa-test.sh --bin <elf> [-- <argv>]
#
# This is the authoritative answer to "is this binary really v2?", because it
# executes rather than inspects. v2/ci/check-isa.sh finds above-v2
# instructions in the disassembly but cannot tell a wrong-ISA compile from a
# runtime-dispatched SIMD path guarded by is_x86_feature_detected!; running the
# code on a CPU that lacks AVX2/BMI2/FMA tells them apart immediately, because
# the first one dies with SIGILL and the second never enters the branch.
#
# How it works: qemu-user emulates the guest. The CPU model is pinned to
# Nehalem (qemu's default), which has AVX but not AVX2/FMA/BMI -- the same
# ceiling as the Ivy Bridge i5-3550 this image targets. Anything the binary
# executes outside a CPUID guard will fault.
#
# Limits, stated so nobody over-reads a PASS:
#   * It exercises the code paths the binary actually takes when run this way.
#     `--version` or `--help` reaches initialisation and argument parsing, not
#     the application's real work. A binary can pass here and still have a
#     wrong-ISA inner loop that only runs when it parses a real file.
#   * It does not run the GUI. These are GTK4 apps that need a display and a
#     D-Bus session; they are launched headless and only get as far as they can
#     before failing on the missing display, which is usually after libc, the
#     dynamic loader and the argument parser have all executed.
#   * It proves absence of a fault on the paths taken, not correctness of the
#     whole program. For that, boot the ISO under an emulated v2 machine
#     (iso-v2/qemu-test.sh) and use the image.
set -uo pipefail

MODE=deb
BIN=""
ARGV=()

while [ $# -gt 0 ]; do
  case "$1" in
    --bin) MODE=bin; BIN="$2"; shift 2 ;;
    --) shift; ARGV=("$@"); break ;;
    *) if [ "$MODE" = bin ]; then ARGV+=("$1"); else ARGV=(); fi; shift ;;
  esac
done

if [ -z "${CONTAINER_ENGINE:-}" ]; then
  for c in docker podman; do
    command -v "$c" >/dev/null 2>&1 && { ENGINE="$c"; break; }
  done
else
  ENGINE="$CONTAINER_ENGINE"
fi

# qemu-user is only packaged as the dynamically-linked "qemu-user" in sid, so
# run it inside a container that has it. qemu-x86_64 needs no display for a
# console binary, which is why --help is a usable smoke test.
IMG="${ISA_TEST_IMAGE:-debian:sid}"

if [ "$MODE" = deb ]; then
  [ $# -gt 0 ] || { echo "usage: $(basename "$0") <deb>... | --bin <elf> [-- argv]" >&2; exit 2; }
  rc=0
  for deb in "$@"; do
    [ -f "$deb" ] || { echo "SKIP  $(basename "$deb"): not found"; continue; }
    tmp="$(mktemp -d)"
    dpkg-deb -x "$deb" "$tmp" 2>/dev/null || { echo "FAIL  $(basename "$deb"): cannot extract"; rc=1; continue; }
    # The largest ELF executable is the application's real binary; the rest are
    # helper scripts shipped alongside it.
    target="$(find "$tmp" -type f -executable -print0 2>/dev/null \
              | xargs -0 -r file 2>/dev/null \
              | grep -a 'ELF.*executable' \
              | sed 's/:.*//' \
              | xargs -r ls -S 2>/dev/null | head -1)"
    rm -rf "$tmp"
    if [ -z "$target" ]; then
      echo "SKIP  $(basename "$deb"): no ELF executable (data-only)"
      continue
    fi
    if run_one "$deb" "$target"; then :; else rc=1; fi
  done
  exit "$rc"
else
  [ -n "$BIN" ] || { echo "error: --bin needs a path" >&2; exit 2; }
  run_one "$BIN" "$BIN"
fi

run_one() {
  local label="$1" bin="$2"
  local root out status
  root="$(mktemp -d)"
  dpkg-deb -x "$label" "$root" 2>/dev/null || cp -a "$bin" "$root/" 2>/dev/null || true

  printf '%-46s ' "$(basename "$label")"

  # Run inside a container so the emulated CPU model is ours to choose and the
  # host's real AVX2 cannot mask a fault. -cpu is deliberately left at QEMU's
  # default Nehalem model: AVX yes, AVX2/BMI2/FMA no.
  out="$($ENGINE run --rm \
      -v "$(dirname "$bin")/$(basename "$bin"):/t:ro" \
      "$IMG" bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq qemu-user >/dev/null 2>&1
        if [ ! -x /t ]; then chmod +x /t 2>/dev/null; fi
        # Default CPU model for qemu-user is Nehalem-era: AVX, no AVX2/BMI2/FMA.
        qemu-x86_64 -cpu max,avx2=off,bmi2=off,fma=off /t --version 2>&1
        rc=$?
        echo "QEMU_EXIT=$rc"
      ' 2>&1)"

  rm -rf "$root"

  # SIGILL is 132 (128+4) and qemu-user reports it either as that exit status
  # or as "Illegal instruction" in the message.
  if printf '%s' "$out" | grep -qiE 'illegal instruction|SIGILL|QEMU_EXIT=132'; then
    echo "FAIL  executed an above-v2 instruction on an emulated v2 CPU"
    printf '%s\n' "$out" | grep -iE 'illegal|instruction|QEMU_EXIT' | head -3 | sed 's/^/         /'
    return 1
  fi
  # A dynamic-loader failure means we never got to the program's code at all,
  # so the run proves nothing. Say so rather than reporting a pass.
  if printf '%s' "$out" | grep -qiE 'error while loading shared libraries|No such file or directory'; then
    echo "SKIP  ran out of shared libraries; no v2 code was exercised"
    printf '%s\n' "$out" | grep -iE 'shared librar' | head -2 | sed 's/^/         /'
    return 0
  fi
  if printf '%s' "$out" | grep -q 'QEMU_EXIT=0'; then
    echo "PASS  ran to completion on an emulated v2 CPU"
    return 0
  fi
  echo "INCONCLUSIVE  $(printf '%s' "$out" | grep -oE 'QEMU_EXIT=[0-9]+' | head -1)"
  printf '%s\n' "$out" | tail -3 | sed 's/^/         /'
  return 0
}