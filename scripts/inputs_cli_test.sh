#!/usr/bin/env bash
# The input set through the command: merge refuses an output inside a directory read through a
# list; merge3 of versions given as globs is a set (every document written to -o DIR); diff and
# merge3 print the files they read. No schema needed.
#
#   scripts/inputs_cli_test.sh [path to the arxmodel binary]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$(realpath "${1:-$root/bin/arxmodel}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unset ARXMODEL_SCHEMA_DIR
export XDG_CONFIG_HOME="$work/config"
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$work"

# three versions of a two-file model
for v in base ours theirs; do
	mkdir -p "$v/a" "$v/b"
	cp "$root/testdata/compare/base.arxml" "$v/a/one.arxml"
	sed 's|<SHORT-NAME>Body</SHORT-NAME>|<SHORT-NAME>Cabin</SHORT-NAME>|' "$root/testdata/compare/base.arxml" > "$v/b/two.arxml"
done
sed -i 's|<WATTS>55</WATTS>|<WATTS>60</WATTS>|' ours/a/one.arxml
sed -i 's|<WATTS>5</WATTS>|<WATTS>7</WATTS>|' theirs/b/two.arxml

# merge3 of globs: a set, both documents written under -o DIR
if "$bin" merge3 'base/*/*.arxml' 'ours/*/*.arxml' 'theirs/*/*.arxml' > /dev/null 2>&1; then
	fail 'merge3 of globs without -o DIR'
fi
"$bin" merge3 'base/*/*.arxml' 'ours/*/*.arxml' 'theirs/*/*.arxml' -o out 2> merge3.log || { cat merge3.log; fail 'merge3 of globs'; }
grep -q '<WATTS>60</WATTS>' out/a/one.arxml || fail 'ours lost'
grep -q '<WATTS>7</WATTS>' out/b/two.arxml || fail "theirs' second document lost"
grep -q 'base/\*/\*.arxml: 2 files' merge3.log || { cat merge3.log; fail 'merge3 does not list its files'; }

# diff prints the files it read
"$bin" diff base ours > /dev/null 2> diff.log || true
grep -q '^base: 2 files' diff.log && grep -q 'base/a/one.arxml' diff.log || { cat diff.log; fail 'diff does not list its files'; }

# merge refuses an output inside a directory read through a list
echo "$work/base/a" > list.txt
if "$bin" merge --no-schema --force -o base/a/merged.arxml @list.txt > /dev/null 2> merge.log; then
	fail 'merge wrote inside a directory read through a list'
fi
grep -q 'inside' merge.log || { cat merge.log; fail 'the clash is not said'; }
echo 'input set CLI test: ok'
