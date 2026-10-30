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

# merge3 of single files whose names hold * and @: each file is itself, merged to standard output
cp base/a/one.arxml 'base*.arxml'; cp ours/a/one.arxml '@ours.arxml'; cp theirs/a/one.arxml 'theirs?.arxml'
"$bin" merge3 'base*.arxml' '@ours.arxml' 'theirs?.arxml' > single.arxml 2> single.log || { cat single.log; fail 'merge3 of special-named single files'; }
grep -q '<WATTS>60</WATTS>' single.arxml || fail 'merge3 of special-named single files lost ours'

# diff prints the files it read
"$bin" diff base ours > /dev/null 2> diff.log || true
grep -q '^base: 2 files' diff.log && grep -q 'base/a/one.arxml' diff.log || { cat diff.log; fail 'diff does not list its files'; }

# merge refuses an output inside a directory read through a list
echo "$work/base/a" > list.txt
if "$bin" merge --no-schema --force -o base/a/merged.arxml @list.txt > /dev/null 2> merge.log; then
	fail 'merge wrote inside a directory read through a list'
fi
grep -q 'inside' merge.log || { cat merge.log; fail 'the clash is not said'; }
# --schema names one schema, whatever the files declare; `policy --schema` stays what it was
lib="$root/testdata/schemas/LIB_2/LIB_2.xsd"
"$bin" check --schema "$lib" "$root/testdata/releases/newest.arxml" > one.log 2>&1 || { cat one.log; fail 'check --schema'; }
grep -q 'rules: schema LIB_2.xsd (--schema)' one.log || { cat one.log; fail 'the rules line does not say --schema'; }
if "$bin" check --schema "$lib" --schema-dir "$root/testdata/schemas" base > /dev/null 2>&1; then
	fail 'check took --schema with --schema-dir'
fi
mkdir in exported
echo '<LIBRARY xmlns="urn:arxmodel:test:lib"><SHELVES/></LIBRARY>' > in/bare.arxml
"$bin" merge --schema "$lib" -o exported/m.arxml in/bare.arxml > merge.log 2>&1 || { cat merge.log; fail 'merge --schema'; }
grep -q 'schemaLocation="urn:arxmodel:test:lib LIB_2.xsd"' exported/m.arxml || { cat exported/m.arxml; fail 'the export names no schema'; }
"$bin" check --schema-dir "$root/testdata/schemas" exported/m.arxml > merge.log 2>&1 || { cat merge.log; fail 'the export does not load'; }
"$bin" diff --schema "$lib" /dev/null in/bare.arxml > diff.log 2>&1 || true
if grep -q 'namespaces declared' diff.log; then cat diff.log; fail 'diff --schema with an empty side'; fi
if "$bin" check --schema nope.xsd base > /dev/null 2>&1; then fail 'check took a schema that is not there'; fi
"$bin" policy --schema | grep -q '"properties"' || fail 'policy --schema'
echo 'input set CLI test: ok'
