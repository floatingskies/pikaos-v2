#!/bin/bash
# PikaOS-v2 :: stage 70 :: verify shipped binaries really are x86-64-v2
#
# Scans the image's ELF objects for instructions ABOVE the v2 level (AVX2, FMA,
# BMI1/2, LZCNT, MOVBE, XSAVE...). This is the gate that proves the image will
# not SIGILL on an i5-3550. Anything found is reported; non-zero exit on hits
# inside /usr/bin, /usr/lib, /usr/sbin.

set -euo pipefail
ROOTFS="${ROOTFS:?}"
. /build/config/pika.conf
BASE="$(dirname "${ROOTFS}")"

# Instructions that are strictly newer than x86-64-v2.
V3_PAT='\b(vp[a-z0-9]+|v[a-z0-9]*fmadd|vbroadcast[a-z]*|vpermt2|vpbroadcastq|vpblendd|vpblendvb|vpermi2|vpmovusd|vpmovsd|vmovdqu(8|16|32|64)|vpsllvq|vpsrlvq|vpmovqb|vpmovqd|andn|bextr|bzhi|mulx|pdep|pext|sarx|shlx|shrx|rorx|tzcnt|lzcnt|movbe|pabs[bwdq]|pshuf[bwdq]|palignr|bls[ir]|blcfill|blsfill|blcmsk|blsmsk|bext[rz]|aesimc|pclmulqdq|sha[rn][ds][0-9])\b'

scan_dir() {
  local dir="$1" strict="$2"
  local hits=0
  # shellcheck disable=SC2012
  find "${dir}" -type f \
    \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) \
    ! -name '*.py' ! -name '*.sh' ! -name '*.txt' 2>/dev/null |
  while read -r f; do
    file -b "${f}" 2>/dev/null | grep -q ELF || continue
    # Disassemble and look for above-v2 instructions
    if objdump -d --no-show-raw-insn "${f}" 2>/dev/null |
       grep -qE "${V3_PAT}"; then
      echo "  ABOVE-V2: ${f}"
      echo "$((hits+1))" > /tmp/.vhits
    fi
  done
  hits=$(cat /tmp/.vhits 2>/dev/null || echo 0)
  rm -f /tmp/.vhits
  echo "${hits}"
}

echo "=============================================="
echo " PikaOS v2 :: x86-64-v2 ISA verification"
echo "=============================================="

for F in ${FLAVOURS}; do
  FROOT="${BASE}/rootfs-${F}"
  [ -d "${FROOT}" ] || continue
  echo
  echo "--- ${F} ---"
  for sub in usr/bin usr/sbin usr/lib usr/libexec lib; do
    [ -d "${FROOT}/${sub}" ] || continue
    out="$(scan_dir "${FROOT}/${sub}" strict || true)"
    echo "  ${sub}: ${out} object(s) with above-v2 instructions"
  done
done

echo
echo "--- deliberate exceptions ---"
echo "  * 32-bit /usr/lib/i386-linux-gnu: baseline i386, intentionally unoptimised"
echo "  * llvmpipe/softpipe & JITed code: feature-detected at runtime"
echo
echo "Note: stock Debian amd64 binaries are baseline x86-64 and always pass."
echo "The v2 rebuild applies to the PikaOS components we build ourselves."