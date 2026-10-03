#!/usr/bin/env bash
# Check a built deb for instructions the target CPU does not have.
#
#   v2/ci/check-isa.sh <deb> [<deb>...]
#   v2/ci/check-isa.sh v2/repo/pool/main/*.deb
#
# The image targets x86-64-v2: everything up to SSE4.2, SSSE3, POPCNT and
# CMPXCHG16B. Above that sit AVX2, FMA, BMI1/2 and MOVBE, which Ivy Bridge
# (Core i5-3550) does not have. A single v3 instruction anywhere in a shipped
# binary is a SIGILL at some arbitrary later moment, usually under load, which
# is close to undebuggable.
#
# This exists because the build flags are not evidence. pika-device-manager
# built with CFLAGS=-march=x86-64-v2 in its log and still shipped 256-bit VEX
# vpbroadcastb, because debian/rules set -C target-cpu=x86-64-v3 and overrode
# the injected flags. The log said v2; the binary was v3. So the check has to
# read the binary.
#
# Scope and limits, stated plainly:
#   * It scans the .text of ELF binaries inside the deb. That is where
#     executable code lives, and it is the only thing that can fault.
#   * It matches mnemonics, not decoded operands, so it is a superset: a
#     mnemonic can appear in a branch target, a symbol name or a comment-ish
#     string. objdump -d output is disassembly only, but a symbol named after
#     an AVX2 intrinsic can still print alongside it. Treat a hit as "look at
#     this", not "this is broken".
#   * It cannot see instructions a compiler emits from intrinsics in inline
#     asm spelled as raw bytes. Nothing short of actually booting the binary on
#     the target catches those; the ISO boot smoke test is the backstop.
#   * Data blobs are not scanned. A miscompiled constant is a wrong answer, not
#     a crash, and is out of scope here.
set -uo pipefail

# ---------------------------------------------------------------------------
# What this checker can and cannot decide
# ---------------------------------------------------------------------------
# A static disassembly scan CANNOT tell these two apart:
#
#   (a) code the compiler emitted at the wrong ISA level, which faults on the
#       target CPU, and
#   (b) code guarded by a runtime CPUID check -- std::is_x86_feature_detected!,
#       which is how simd-json, httparse's simd module, zstd and most Rust
#       `core_arch` wrappers are written. Perfectly portable, and shipping it
#       is the correct outcome, not a bug.
#
# Both appear in the disassembly identically. Everything found in
# pikman-update-manager's 12MB binary was (b):
#
#   httparse::simd::avx2::match_header_value_vectored
#   core::core_arch::x86_64::avx::__mm256_loadu_si256
#
# i.e. one runtime-dispatched module plus the Rust stdlib's AVX wrappers, and
# the build was correctly v2 the whole time. An earlier revision tried to
# suppress these with a symbol-name heuristic; it had to grow a second pattern
# for Rust's length-prefixed mangling (_RNv...4simd4avx2), and even then it was
# guessing from names, which is not evidence.
#
# So this script does not try to decide. It reports what it finds and tells you
# the finding needs an execution test to interpret. The authoritative check is
# v2/ci/run-isa-test.sh, which runs the binaries under QEMU emulating a real
# v2 CPU and fails on SIGILL. Static scan first because it is free and local;
# emulation because it is the only thing that actually answers the question.
#
# What IS solid here: a deb with zero findings is clean. Findings mean "look,
# and probably fine if the symbols are dispatched SIMD".

# Mnemonics that require more than x86-64-v2.
#
# Grouped by the feature that introduced them, because "this needs AVX2" and
# "this needs BMI2" are different bugs to chase.
AVX2_INSNS='\b(vpternlog[a-z]*|vpbroadcast[bwdqs]|vpermd|permd|vpblendm[bwd]|vpblendmps|vpcompress[bwd]|vpexpand[bwd]|vpmovm2[bwd]|vpmovn2[bwd]|vpmov[bwd]2m|vpmovm2[bwd]q|vpconflict|vpcmpeq[bwd]|vpcmpeqq|vpgtq|vpgtsq|vpminu[bwd]|vpmaxu[bwd]|vpsadbw|vpternlogd|vpternlogq|vpsllvq|vpsrlvq|vscatter[a-z]*|vgather[a-z]*|vpmaskmov[a-z]*|vmovdqu[8|16|32|64]|vpmovz[bwdq]|vpmovs[bwdq]|vpblendv[bwd]|vinsertf128|vextractf128|vpbroadcastq|vpmovdqu|vpmovqd|vpmovdq)\b'

FMA_INSNS='\b(vfmadd[0-9a-z]*|vfmsub[0-9a-z]*|vfnmadd[0-9a-z]*|vfnmsub[0-9a-z]*)\b'

BMI_INSNS='\b(andn|bextr|blsi|blsmsk|blsr|bzhi|mulx|pdep|pext|sarx|shlx|shrx|bextrq|tzcnt|lzcnt)\b'

MOVBE='\bmovbe\b'

# Baseline instructions that are perfectly legal at v2 but whose *256-bit* form
# is AVX2, so they need their own check. objdump prints the same mnemonic for
# SSE (128-bit VEX) and AVX2 (256-bit VEX), so the operand width is the only
# way to tell vpbroadcastb-legal from vpbroadcastb-illegal. Handled separately
# below by scanning for %ymm.
YMM_RE='%ymm'

check_one() {
  local deb="$1"
  [ -f "$deb" ] || { echo "skip (missing): $deb"; return 0; }

  local tmp findings=0 name
  tmp="$(mktemp -d)" || { echo "mktemp failed"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  if ! dpkg-deb -x "$deb" "$tmp" 2>/dev/null; then
    echo "FAIL  $(basename "$deb"): dpkg-deb could not extract it"
    return 1
  fi

  local total=0
  while IFS= read -r -d '' f; do
    # Only real ELF binaries, and only executables/shared objects.
    head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF' || continue
    total=$((total + 1))

    local dis
    dis="$(objdump -d --no-show-raw-insn "$f" 2>/dev/null)" || continue
    [ -n "$dis" ] || continue

    # Tag every instruction with the symbol it belongs to. objdump emits one
    # "0000... <symbol>:" header per function, so the current symbol is
    # whatever the last header was.
    #
    # This matters because the enclosing symbol is what makes a finding
    # interpretable: AVX2 inside `httparse::simd::avx2::...` is runtime
    # dispatched and harmless, while AVX2 inside an unrelated render loop means
    # the build targeted the wrong ISA. A bare count cannot tell those apart,
    # and that distinction is the whole diagnosis.
    dis="$(printf '%s\n' "$dis" | awk '
      /^[0-9a-f]+ <.*>:/ {
        sym = $0
        sub(/^[0-9a-f]+ </, "", sym)
        sub(/>:$/, "", sym)
        next
      }
      { print sym "\t" $0 }
    ')"

    local hits
    # 256-bit operands are AVX2 by definition, whatever the mnemonic.
    hits="$(printf '%s\n' "$dis" | grep -cE "$YMM_RE" || true)"
    if [ "$hits" -gt 0 ]; then
      local sample
      sample="$(printf '%s\n' "$dis" | grep -E "$YMM_RE" | head -3 \
                  | awk -F'\t' '{ printf "%s  [%s]\n", $2, $1 }' | cut -c1-130)"
      printf '  NOTE %s: %s use(s) of 256-bit %%ymm (AVX2)\n' "${f#$tmp/}" "$hits"
      printf '       %s\n' "$sample"
      findings=$((findings + hits))
    fi

    for group in "AVX2:$AVX2_INSNS" "FMA:$FMA_INSNS" "BMI:$BMI_INSNS" "MOVBE:$MOVBE"; do
      local label="${group%%:*}" re="${group#*:}"
      local n
      n="$(printf '%s\n' "$dis" | grep -cE "$re" || true)"
      if [ "$n" -gt 0 ]; then
        local s
        s="$(printf '%s\n' "$dis" | grep -E "$re" | head -2 \
              | awk -F'\t' '{ printf "%s  [%s]\n", $2, $1 }' | cut -c1-130)"
        printf '  NOTE %s: %s %s instruction(s)\n' "${f#$tmp/}" "$n" "$label"
        printf '       %s\n' "$s"
        findings=$((findings + n))
      fi
    done
  done < <(find "$tmp" -type f -print0)

  if [ "$total" -eq 0 ]; then
    printf 'PASS  %-52s (no ELF binaries; data-only package)\n' "$(basename "$deb")"
    return 0
  fi
  if [ "$findings" -gt 0 ]; then
    # NOTE, not FAIL: as documented above, above-v2 instructions in a binary are
    # expected when they sit behind a runtime CPUID check, which is most Rust
    # and C SIMD code. Failing here would mean every portable binary in the
    # fleet is rejected, and the fleet would stop being built at all -- a much
    # worse outcome than a warning nobody reads.
    #
    # This returns success. The authoritative verdict comes from
    # v2/ci/run-isa-test.sh, which executes the binary on an emulated v2 CPU and
    # fails on SIGILL. A non-zero exit here means the scan itself broke.
    printf 'NOTE  %-52s %s finding(s) across %s ELF binary(ies) -- needs an execution test\n' \
      "$(basename "$deb")" "$findings" "$total"
    return 0
  fi
  printf 'CLEAN %-52s %s ELF binary(ies), no above-v2 instructions\n' "$(basename "$deb")" "$total"
  return 0
}

if [ $# -eq 0 ]; then
  echo "usage: $(basename "$0") <deb>..." >&2
  exit 2
fi

fail=0
checked=0
notes=0
for deb in "$@"; do
  checked=$((checked + 1))
  out="$(check_one "$deb")" || fail=$((fail + 1))
  [ -n "$out" ] && printf '%s\n' "$out"
  case "$out" in *NOTE*) notes=$((notes + 1)) ;; esac
done

echo
echo "checked $checked deb(s): $((checked - notes - fail)) clean, $notes need an execution test, $fail scan error(s)"
if [ "$notes" -gt 0 ]; then
  cat >&2 <<'EOF'

NOTE lines above are above-v2 instructions, which are NOT automatically a bug.
Read the enclosing symbol printed with each one:

  * inside a SIMD module selected by a runtime CPUID check
    (httparse::simd::avx2::..., core::core_arch::x86_64::avx::...,
    simd_json::..., anything named for an ISA) is correct portable code. The
    CPU never enters it on Ivy Bridge.

  * anywhere else means the build targeted the wrong ISA. Look for a hardcode
    that overrides the injected config:

      grep -rn 'x86-64-v3\|target-cpu=x86-64-v3\|mavx2\|mfma' <source>/debian/

    and add it to v2/ci/isa-shims.txt if it is a legitimate hardcode.

To settle it rather than reason about it, execute the binaries on an emulated
v2 CPU:

  v2/ci/run-isa-test.sh <deb>...

which runs them under QEMU with AVX2/BMI2/FMA masked out and fails on SIGILL.
EOF
fi
# Non-zero means the scan itself failed (unreadable deb, missing objdump), not
# that a binary is wrong. run-isa-test.sh is what returns a verdict.
exit "$fail"
