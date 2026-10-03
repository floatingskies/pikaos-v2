#! /bin/bash
# Fail early, and precisely, when a package the ISO installs cannot be resolved.
#
# apt's own report for a broken closure is hundreds of lines of "but it is not
# going to be installed", with the one real cause buried at the top. This walks
# the closure instead and prints the names that sid does not have.
#
# Runs INSIDE the pika-v2-builder image (Debian sid, so apt knows the same
# package set the ISO will use):
#
#   ./v2/ci/check-sid-deps.sh <Packages-file> <recipe-file>
set -euo pipefail

PACKAGES_FILE="${1:?usage: check-sid-deps.sh <Packages> <recipe>}"
RECIPE_FILE="${2:?usage: check-sid-deps.sh <Packages> <recipe>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

apt-get update -qq >/dev/null

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
external="$WORK/external.txt"

python3 "$HERE/dep-closure.py" "$PACKAGES_FILE" "$HERE/dep-shims.tsv" "$RECIPE_FILE" \
    > "$external" \
    || { echo "::error::the recipe names a package that is not in the v2 index"; exit 1; }

echo "::group::closure: $(wc -l < "$external") dependencies must come from Debian sid"

# apt-cache reports "Candidate: (none)" for a package it has never heard of, and
# a previous version of this check read that as "found" because the field was
# non-empty. Treat (none) as missing.
missing=0
: > "$WORK/missing.txt"
while read -r dep; do
    [ -z "$dep" ] && continue
    candidate="$(apt-cache policy "$dep" 2>/dev/null | sed -n 's/^  Candidate: //p')"
    if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
        echo "  MISSING: $dep" | tee -a "$WORK/missing.txt"
        missing=$((missing + 1))
    fi
done < "$external"
echo "::endgroup::"

if [ "$missing" -gt 0 ]; then
    cat <<EOF
::error::$missing dependency(ies) the ISO needs are not in Debian sid and have no shim:
$(sed 's/^/  /' "$WORK/missing.txt")
Either build the package and add it to v2/ci/packages.tsv, or record the
substitute in v2/ci/dep-shims.tsv.
EOF
    exit 1
fi

echo "dependency closure resolves against Debian sid"