#!/usr/bin/env bash
# Copy flatxml's library (the flatxml/ folder, flatxml.xsd included) at a stated commit into
# flatxml/ here, and record the commit in flatxml/VENDORED. The copy is never edited: to change
# it, vendor another commit. Tests are left out, since they read flatxml's own test data.
#
#   scripts/vendor_flatxml.sh <full commit sha> [flatxml checkout or URL]
set -euo pipefail
commit=${1:?usage: vendor_flatxml.sh <commit> [flatxml checkout or URL]}
src=${2:-https://github.com/MartenH/flatxml}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -C "$work" init -q
git -C "$work" fetch -q --depth=1 "$src" "$commit"
full=$(git -C "$work" rev-parse FETCH_HEAD)
# a local checkout is recorded by its origin, never by its path on this machine
if [ -d "$src" ]; then
	src=$(git -C "$src" remote get-url origin | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')
fi
git -C "$work" checkout -q FETCH_HEAD -- flatxml
find "$work/flatxml" -name '*_test.v' -delete
rm -rf "$root/flatxml"
cp -R "$work/flatxml" "$root/flatxml"
printf 'flatxml %s\nsource %s\nThe library folder at that commit, without its tests. Do not edit; re-vendor.\n' \
	"$full" "$src" > "$root/flatxml/VENDORED"
# the library carries VENDORED built in (arxmodel/builtin.v): regenerate it
v run "$root/scripts/gen_builtin.vsh"
echo "vendored flatxml ${full}"
