#!/usr/bin/env bash
# values and --ignore-element through the command, on the synthetic compare model, no schema
# needed: values prints `path = "text"` lines and exits 1 when nothing matches; diff leaves an
# element it is told to ignore out, inside a value of a set too.
#
#   scripts/values_cli_test.sh [path to the arxmodel binary]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$(realpath "${1:-$root/bin/arxmodel}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unset ARXMODEL_SCHEMA_DIR
export XDG_CONFIG_HOME="$work/config"
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$work"
model="$root/testdata/compare/base.arxml"

# values: a definition's value by its last name, anywhere
"$bin" values '/**/Dim' "$model" > dim.txt 2> dim.log || { cat dim.log; fail 'values /**/Dim'; }
[[ "$(cat dim.txt)" == '/Body/LampCfg/Dim = "10"' ]] || { cat dim.txt; fail 'values /**/Dim printed something else'; }
grep -q '^1 value$' dim.log || { cat dim.log; fail 'values does not count what it printed'; }

# an element's path: every value below it; --ignore-element leaves one out
"$bin" values /Body/Head "$model" > head.txt 2> /dev/null
[[ $(wc -l < head.txt) == 3 ]] || { cat head.txt; fail 'values /Body/Head'; }
"$bin" values --ignore-element NOTES /Body/Head "$model" > head2.txt 2> /dev/null
[[ "$(cat head2.txt)" == '/Body/Head#WATTS = "55"' ]] || { cat head2.txt; fail 'values --ignore-element'; }

# nothing matching: exit 1; no path pattern: exit 2
set +e
"$bin" values '/Nowhere/**' "$model" > /dev/null 2>&1
[[ $? == 1 ]] || fail 'values matching nothing does not exit 1'
"$bin" values "$model" "$model" > /dev/null 2>&1
[[ $? == 2 ]] || fail 'values without a path pattern does not exit 2'
set -e

# diff: a note added inside a value of a set and inside a value of one definition
two='            <SIGNAL-REFERENCE-VALUE>NOTE
              <DEFINITION-REF DEST="REF-DEF">/Defs/Lamp/Signal</DEFINITION-REF>
              <VALUE-REF DEST="SIGNAL">/Sig/B</VALUE-REF>
            </SIGNAL-REFERENCE-VALUE>'
for v in old new; do
	note=''
	[[ $v == new ]] && note='<NOTES><NOTE>derived</NOTE></NOTES>'
	awk -v add="${two/NOTE/$note}" -v note="$note" '
		{ if (note != "" && $0 ~ /<VALUE>10<\/VALUE>/) sub(/<VALUE>10/, note "<VALUE>10"); print }
		/<\/SIGNAL-REFERENCE-VALUE>/ && !done { print add; done = 1 }' "$model" > "$v.arxml"
done
set +e
"$bin" diff old.arxml new.arxml > diff.txt 2> /dev/null
[[ $? == 1 ]] || { cat diff.txt; fail 'diff of a note added is no change'; }
"$bin" diff --ignore-element NOTES old.arxml new.arxml > diff2.txt 2> /dev/null
[[ $? == 0 ]] || { cat diff2.txt; fail 'diff --ignore-element NOTES still differs'; }
set -e
echo 'values_cli_test: ok'
