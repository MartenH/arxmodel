#!/usr/bin/env bash
# values through the command, on the synthetic compare model, no schema needed: values prints
# `path = "text"` lines and exits 1 when nothing matches, 2 without a pattern.
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

# an element's path: every value below it
"$bin" values /Body/Head "$model" > head.txt 2> /dev/null
[[ $(wc -l < head.txt) == 3 ]] || { cat head.txt; fail 'values /Body/Head'; }

# nothing matching: exit 1; no path pattern: exit 2
set +e
"$bin" values '/Nowhere/**' "$model" > /dev/null 2>&1
[[ $? == 1 ]] || fail 'values matching nothing does not exit 1'
"$bin" values "$model" "$model" > /dev/null 2>&1
[[ $? == 2 ]] || fail 'values without a path pattern does not exit 2'
set -e

echo 'values_cli_test: ok'
