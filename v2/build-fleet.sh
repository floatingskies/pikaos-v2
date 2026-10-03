#!/usr/bin/env bash
# Build the whole x86-64-v2 package fleet, locally, into v2/repo/pool/main.
#
# Usage:
#   v2/build-fleet.sh                     # everything in v2/ci/packages.tsv
#   v2/build-fleet.sh --limit 20          # first 20 (a smoke run)
#   v2/build-fleet.sh --only boot-packages multimedia-packages
#   v2/build-fleet.sh --skip-exists       # don't rebuild what already built
#
# This is the local counterpart to the v2-packages.yml CI matrix: same list
# (v2/ci/packages.tsv), same per-package builder (v2/pkg-build.sh), same pool.
# The point of having it is that the fleet is 268 packages on a 4-core box, so
# you want to be able to run a slice, resume, and see what failed without
# re-reading a matrix on a web page.
#
# Differences from CI, on purpose:
#   * serial, not a matrix. One box, four cores; a matrix here would thrash.
#   * keeps going after a failure, recording it, so a partial fleet is still
#     usable -- same reasoning as the CI chunk loop.
#   * writes a machine-readable report of what built and what did not.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TSV="$HERE/ci/packages.tsv"
POOL="$HERE/repo/pool/main"
REPORT="$HERE/repo/fleet-build-report.tsv"
LOGDIR="${PIKA_FLEET_LOGS:-$HERE/work/fleet-logs}"

LIMIT=0
ONLY=()
SKIP_EXISTS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --only) shift; while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do ONLY+=("$1"); shift; done ;;
    --skip-exists) SKIP_EXISTS=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -n "${CONTAINER_ENGINE:-}" ]; then
  ENGINE="$CONTAINER_ENGINE"
else
  ENGINE=""
  for c in docker podman; do
    command -v "$c" >/dev/null 2>&1 && { ENGINE="$c"; break; }
  done
fi
[ -n "$ENGINE" ] || { echo "error: no container runtime (docker or podman)" >&2; exit 2; }

mkdir -p "$POOL" "$LOGDIR"

# ------------------------------------------------------------------ the list
mapfile -t ALL < <(grep -vE '^[[:space:]]*(#|$)' "$TSV")
[ "${#ALL[@]}" -gt 0 ] || { echo "error: $TSV is empty" >&2; exit 1; }

if [ "${#ONLY[@]}" -gt 0 ]; then
  mapfile -t PICK < <(printf '%s\n' "${ALL[@]}" | grep -E "^($(IFS='|'; echo "${ONLY[*]}"))/")
else
  PICK=("${ALL[@]}")
fi
[ "${#PICK[@]}" -gt 0 ] || { echo "error: --only matched nothing" >&2; exit 2; }
if [ "$LIMIT" -gt 0 ] && [ "$LIMIT" -lt "${#PICK[@]}" ]; then
  PICK=("${PICK[@]:0:$LIMIT}")
fi

TOTAL="${#PICK[@]}"
echo "engine:    $ENGINE"
echo "fleet:     $TOTAL package(s) selected (of ${#ALL[@]} in the list)"
echo "pool:      $POOL"
echo "logs:      $LOGDIR"
echo

printf 'package\tstatus\tdetail\n' > "$REPORT"
BUILT=0; FAILED=0; CACHED=0
FAILED_LIST=()
START_ALL=$(date +%s)

for i in "${!PICK[@]}"; do
  pkg="${PICK[$i]}"
  n=$((i + 1))
  slug="${pkg//\//-}"
  log="$LOGDIR/$slug.log"
  start=$(date +%s)

  # Skip work that already produced a deb, so a resumed run is cheap.
  #
  # Ask pkg-build.sh's own cache instead of reimplementing the stamp logic: it
  # already encodes "this package's upstream commit and build inputs are
  # unchanged AND the debs it names still exist". Duplicating that here is how
  # you end up skipping a package that needs rebuilding -- the first draft of
  # this check compared the stamp's first line to the slug, which the stamp
  # never contains (it holds a git SHA), so it never matched.
  if [ "$SKIP_EXISTS" = 1 ]; then
    if "$HERE/pkg-build.sh" "$pkg" > "$log" 2>&1; then
      if grep -q 'is up to date; reusing the cached deb' "$log"; then
        printf '[%3d/%3d] %-46s cached\n' "$n" "$TOTAL" "$pkg"
        printf '%s\tcached\t\n' "$pkg" >> "$REPORT"
        CACHED=$((CACHED + 1))
        continue
      fi
      # Not cached, but it did build on this call: fall through to the normal
      # path below would rebuild it, so record it here instead.
      dur=$(( $(date +%s) - start ))
      printf 'ok (%ss)\n' "$dur"
      printf '%s\tbuilt\t%ss\n' "$pkg" "$dur" >> "$REPORT"
      BUILT=$((BUILT + 1))
      continue
    else
      printf '[%3d/%3d] %-46s ' "$n" "$TOTAL" "$pkg"
      dur=$(( $(date +%s) - start ))
      printf 'FAILED (%ss) -> %s\n' "$dur" "${log#$HERE/}"
      reason="$(grep -m1 -iE '^ERROR|error:|fatal|not found|No such file' "$log" 2>/dev/null | cut -c1-120)"
      printf '%s\tfailed\t%s\n' "$pkg" "$reason" >> "$REPORT"
      FAILED_LIST+=("$pkg")
      FAILED=$((FAILED + 1))
      continue
    fi
  fi

  printf '[%3d/%3d] %-46s ' "$n" "$TOTAL" "$pkg"
  # A stale work tree from an interrupted run is a trap: pkg-build.sh does
  # `rm -rf` on the work dir before cloning, and if a previous rootless-podman
  # build left it owned by a subuid that rm fails with "Permission denied" and
  # the package never builds. Clear it first, from the host side.
  wdir="$HERE/work/${pkg//\//__}"
  if [ -e "$wdir" ] && [ -n "$(find "$wdir" ! -user "$(id -u)" -print -quit 2>/dev/null)" ]; then
    printf '(reclaiming) '
    if [ "$ENGINE" = podman ]; then
      podman unshare chown -R "$(id -u):$(id -g)" "$wdir" 2>/dev/null || true
    fi
    rm -rf "$wdir" 2>/dev/null || podman unshare rm -rf "$wdir" 2>/dev/null || true
  fi

  if "$HERE/pkg-build.sh" "$pkg" > "$log" 2>&1; then
    dur=$(( $(date +%s) - start ))
    printf 'ok (%ss)\n' "$dur"
    printf '%s\tbuilt\t%ss\n' "$pkg" "$dur" >> "$REPORT"
    BUILT=$((BUILT + 1))
  else
    dur=$(( $(date +%s) - start ))
    printf 'FAILED (%ss) -> %s\n' "$dur" "${log#$HERE/}"
    # First line that looks like the actual cause, not the wrapper's exit line.
    reason="$(grep -m1 -iE '^ERROR|error:|fatal|not found|No such file' "$log" 2>/dev/null | cut -c1-120)"
    printf '%s\tfailed\t%s\n' "$pkg" "$reason" >> "$REPORT"
    FAILED_LIST+=("$pkg")
    FAILED=$((FAILED + 1))
  fi
done

ELAPSED=$(( $(date +%s) - START_ALL ))
echo
echo "=========================================================="
printf 'built %d, cached %d, failed %d of %d in %dm%02ds\n' \
  "$BUILT" "$CACHED" "$FAILED" "$TOTAL" $((ELAPSED / 60)) $((ELAPSED % 60))
echo "debs in pool: $(find "$POOL" -name '*.deb' | wc -l)"
echo "report:       ${REPORT#$HERE/}"
if [ "$FAILED" -gt 0 ]; then
  echo
  echo "failed:"
  printf '  %s\n' "${FAILED_LIST[@]}"
  echo
  echo "each log has the full output; the reason column in the report is the"
  echo "first error line, which is often a symptom rather than the cause."
fi
echo "=========================================================="