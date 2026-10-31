#!/usr/bin/env bash
# Writes check's JSON and JUnit reports of the synthetic models and merge3's report, and validates
# each against its schema: arxmodel's own (docs/report.schema.json, docs/merge3.schema.json) and the
# Jenkins xunit plugin's JUnit XSD. The
# outside schema is fetched at a pinned commit, checked by SHA-256, into DIR (a temporary
# directory by default), never committed. Needs Python with jsonschema
# and lxml ($PYTHON, python by default).
#
# usage: scripts/check_reports.sh ARXMODEL [DIR]
set -euo pipefail
bin=$1
dir=${2:-$(mktemp -d)}
mkdir -p "$dir"
fetch() { # url file sha256
  if [ ! -f "$dir/$2" ] || ! echo "$3  $dir/$2" | sha256sum -c --status; then
    curl -sfL -o "$dir/$2" "$1"
  fi
  echo "$3  $dir/$2" | sha256sum -c --status || { echo "$2: not the file pinned"; exit 2; }
}
fetch https://raw.githubusercontent.com/jenkinsci/xunit-plugin/0afa700702a6617f483cfd9407711976dc0bd74a/src/main/resources/org/jenkinsci/plugins/xunit/types/model/xsd/junit-10.xsd \
  junit-10.xsd a1a816f58d1bf95ebabf371994df0b9246dee66ea9572fbec4f9296f1b2c0ff6
args=()
# each case: a name, then the paths checked (the last two declare different namespaces, so no
# schema governs them and the report says so)
cases=('merge testdata/merge' 'model testdata/model' 'refs testdata/refs' 'export testdata/export'
  'ungoverned testdata/model/a.arxml testdata/roots/items.arxml')
for c in "${cases[@]}"; do
  read -r model paths <<< "$c"
  for f in json junit; do
    rc=0
    # shellcheck disable=SC2086
    "$bin" check --format "$f" --schema-dir testdata/schemas $paths > "$dir/$model.$f" 2>/dev/null || rc=$?
    # 0 clean, 1 errors found; 2 would be the command failing
    [ "$rc" -le 1 ] || { echo "check --format $f testdata/$model exited $rc"; exit 1; }
  done
  args+=(--json "$dir/$model.json" --junit "$dir/$model.junit" "$dir/junit-10.xsd")
done
# merge3's report: a conflict on a value, and a node one side removed, so a side with no node
base=testdata/compare/base.arxml
sed -e 's|<WATTS>55</WATTS>|<WATTS>60</WATTS>|' -e '/<NUMBER-PARAM-VALUE>/,/<\/NUMBER-PARAM-VALUE>/d' "$base" > "$dir/ours.arxml"
sed -e 's|<WATTS>55</WATTS>|<WATTS>65</WATTS>|' -e 's|<VALUE>10</VALUE>|<VALUE>12</VALUE>|' "$base" > "$dir/theirs.arxml"
rc=0
"$bin" merge3 --no-schema --format json "$base" "$dir/ours.arxml" "$dir/theirs.arxml" -o "$dir/merged.arxml" > "$dir/merge3.json" 2>/dev/null || rc=$?
[ "$rc" -eq 1 ] || { echo "merge3 --format json exited $rc"; exit 1; }
args+=(--merge3 "$dir/merge3.json")
${PYTHON:-python} scripts/validate_reports.py "${args[@]}"
scripts/merge3_cli_test.sh "$bin"
