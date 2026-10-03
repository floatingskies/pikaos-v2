#!/usr/bin/env bash
# Install the built v2 pool on this system, in dependency order.
#
#   v2/install-pool.sh              # install everything built
#   v2/install-pool.sh --dry-run    # show the order, install nothing
#   v2/install-pool.sh apx pika-welcome   # install just these (and their deps)
#
# Why this exists: the debs in v2/repo/pool/main depend on each other, and
# `dpkg -i *.deb` processes them in shell-glob order, which is alphabetical:
#
#     dpkg: dependency problems prevent configuration of pika-apx-configs:
#     pika-apx-configs depends on apx; however the package apx is not installed
#     dpkg: error processing package pika-apx-configs (--install):
#      dependency problems - leaving unconfigured
#
# That is not a broken deb -- it is dpkg configuring pika-apx-configs (#4 in the
# fleet) before apx (#23). dpkg -i does not order anything.
#
# Three things this does that a glob does not:
#   1. orders the pool by the Depends fields actually present in the debs, not
#      by guesswork about build order;
#   2. separates pool-internal deps (which it can satisfy from the pool) from
#      sid deps (which apt must fetch), and uses apt for the latter;
#   3. reports what it could not satisfy instead of leaving half-configured
#      packages behind without saying so.
#
# It installs for real, on this machine. Read the --dry-run output first.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL="${PIKA_POOL:-$HERE/repo/pool/main}"
DRY=0
WANT=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1; shift ;;
    --pool) POOL="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) WANT+=("$1"); shift ;;
  esac
done

[ -d "$POOL" ] || { echo "error: no pool at $POOL" >&2; exit 1; }

shopt -s nullglob
DEBS=("$POOL"/*.deb)
[ "${#DEBS[@]}" -gt 0 ] || { echo "error: no debs in $POOL" >&2; exit 1; }

command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb not found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Read the pool
# ---------------------------------------------------------------------------
declare -A pkg_file      # package name -> deb path
declare -A pkg_needs     # package name -> pool-internal deps
declare -A pkg_filever   # package name -> "name version" for apt syntax

for deb in "${DEBS[@]}"; do
  name="$(dpkg-deb -f "$deb" Package 2>/dev/null)" || continue
  ver="$(dpkg-deb -f "$deb" Version 2>/dev/null)"
  deps="$(dpkg-deb -f "$deb" Depends 2>/dev/null)"
  [ -n "$name" ] || continue
  # -dbgsym packages are noise here and their own Depends just adds ordering
  # steps for something nobody is going to install.
  case "$name" in *-dbgsym) continue ;; esac
  pkg_file["$name"]="$deb"
  pkg_filever["$name"]="$name=$ver"
  internal=()
  while IFS= read -r d; do
    [ -n "$d" ] && internal+=("$d")
  done < <(printf '%s\n' "$deps" | tr ',' '\n' \
             | sed 's/^[[:space:]]*//; s/[[:space:]]*|.*//; s/ .*//' \
             | grep -E '^(pika|papirus|plymouth|desktop-base|apx|popsicle|libpikd)')
  pkg_needs["$name"]="${internal[*]:-}"
done

[ "${#pkg_file[@]}" -gt 0 ] || { echo "error: no installable packages in $POOL" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------
if [ "${#WANT[@]}" -gt 0 ]; then
  SELECT=()
  for w in "${WANT[@]}"; do
    if [ -n "${pkg_file[$w]:-}" ]; then
      SELECT+=("$w")
    else
      echo "error: '$w' is not built yet. Available:" >&2
      printf '  %s\n' "${!pkg_file[@]}" | sort >&2
      exit 2
    fi
  done
else
  SELECT=("${!pkg_file[@]}")
fi

# ---------------------------------------------------------------------------
# Topological sort
#
# Kahn's algorithm over the pool-internal dependency graph. Ties break
# alphabetically so the order is stable between runs, which makes a --dry-run
# diff meaningful.
# ---------------------------------------------------------------------------
declare -A indeg=()
declare -A dependents=()
for p in "${SELECT[@]}"; do
  indeg["$p"]=0
  for d in ${pkg_needs[$p]:-}; do
    # only count deps that are actually in our selection
    [ -n "${pkg_file[$d]:-}" ] || continue
    printf '%s\n' "${SELECT[@]}" | grep -qx "$d" || continue
    indeg["$p"]=$(( ${indeg[$p]} + 1 ))
    dependents["$d"]="${dependents[$d]:-} $p"
  done
done

ORDER=()
AVAIL=("${SELECT[@]}")
while [ "${#AVAIL[@]}" -gt 0 ]; do
  pick=""
  for p in "${AVAIL[@]}"; do
    if [ "${indeg[$p]}" -eq 0 ]; then pick="$p"; break; fi
  done
  if [ -z "$pick" ]; then
    # A cycle inside the pool. Report it rather than looping forever.
    echo "error: dependency cycle among: ${AVAIL[*]}" >&2
    exit 3
  fi
  ORDER+=("$pick")
  newavail=()
  for p in "${AVAIL[@]}"; do
    [ "$p" = "$pick" ] && continue
    if [[ " ${dependents[$pick]:-} " == *" $p "* ]]; then
      indeg["$p"]=$(( ${indeg[$p]} - 1 ))
    fi
    newavail+=("$p")
  done
  AVAIL=("${newavail[@]}")
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo "pool:   $POOL"
echo "select: ${#SELECT[@]} package(s) to install, ${#ORDER[@]} after ordering"
echo
printf '%-4s %-32s %s\n' "#" "PACKAGE" "POOL-INTERNAL DEPS"
n=0
for p in "${ORDER[@]}"; do
  n=$((n + 1))
  printf '%-4s %-32s %s\n' "$n" "$p" "${pkg_needs[$p]:-(none)}"
done

# Anything we depend on that is neither in the pool nor installed from sid is
# worth saying out loud before anything is unpacked.
echo
missing=0
for p in "${ORDER[@]}"; do
  for d in ${pkg_needs[$p]:-}; do
    if [ -n "${pkg_file[$d]:-}" ]; then continue; fi
    if dpkg-query -W -f='${Status}' "$d" 2>/dev/null | grep -q "install ok installed"; then continue; fi
    if apt-cache show "$d" >/dev/null 2>&1; then
      echo "  note: $p needs $d, which is not in the pool -- apt will fetch it from sid"
    else
      echo "  WARNING: $p needs $d, which is neither built nor in sid"
      missing=$((missing + 1))
    fi
  done
done
[ "$missing" -gt 0 ] && echo "  ($missing dependency/deps unresolvable)"

if [ "$DRY" = 1 ]; then
  echo
  echo "dry run: nothing installed"
  exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
echo
echo "installing ${#ORDER[@]} package(s) in the order above..."
rc=0

# apt resolves and orders both pool and sid deps in one transaction, which is
# what we want for the *contents*; the ordering pass above exists so the
# operator can see and verify it, and so --dry-run is possible.
# Passing the pool explicitly, with pool-internal deps already satisfied by the
# same invocation, means apt never has to guess.
FILES=()
for p in "${ORDER[@]}"; do FILES+=("${pkg_file[$p]}"); done

sudo apt-get install -y --no-install-recommends "${FILES[@]}" || rc=$?

echo
if [ "$rc" -eq 0 ]; then
  # Confirm rather than trust the exit code: a package can be left
  # half-configured and still exit zero in some paths.
  bad=0
  for p in "${ORDER[@]}"; do
    st="$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || echo '<missing>')"
    case "$st" in
      *"install ok installed") ;;
      *) echo "  NOT FULLY INSTALLED: $p ($st)"; bad=$((bad + 1)) ;;
    esac
  done
  if [ "$bad" -gt 0 ]; then
    echo "$bad package(s) did not reach 'install ok installed'"
    exit 1
  fi
  echo "all ${#ORDER[@]} package(s) installed and configured"
else
  echo "apt-get install exited $rc; check the output above"
fi
exit "$rc"