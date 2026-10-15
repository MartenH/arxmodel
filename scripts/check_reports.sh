#!/usr/bin/env bash
# Writes check's JSON, SARIF and JUnit reports of the synthetic models and validates each against
# its schema: arxmodel's own (docs/report.schema.json), OASIS SARIF 2.1.0 and the Jenkins xunit
# plugin's JUnit XSD. The two outside schemas are fetched at pinned commits, checked by SHA-256,
# into DIR (a temporary directory by default), never committed. Needs Python with jsonschema
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
fetch https://raw.githubusercontent.com/oasis-tcs/sarif-spec/d825fb71286d2bd928122364093d6f449b1cb2c2/sarif-2.1/schema/sarif-schema-2.1.0.json \
  sarif-schema-2.1.0.json c3b4bb2d6093897483348925aaa73af03b3e3f4bd4ca38cef26dcb4212a2682e
fetch https://raw.githubusercontent.com/jenkinsci/xunit-plugin/0afa700702a6617f483cfd9407711976dc0bd74a/src/main/resources/org/jenkinsci/plugins/xunit/types/model/xsd/junit-10.xsd \
  junit-10.xsd a1a816f58d1bf95ebabf371994df0b9246dee66ea9572fbec4f9296f1b2c0ff6
args=()
# each case: a name, then the paths checked (the last two declare different namespaces, so no
# schema governs them and the report says so)
cases=('merge testdata/merge' 'model testdata/model' 'refs testdata/refs' 'export testdata/export'
  'ungoverned testdata/model/a.arxml testdata/roots/items.arxml')
for c in "${cases[@]}"; do
  read -r model paths <<< "$c"
  for f in json sarif junit; do
    rc=0
    # shellcheck disable=SC2086
    "$bin" check --format "$f" --schema-dir testdata/schemas $paths > "$dir/$model.$f" 2>/dev/null || rc=$?
    # 0 clean, 1 errors found; 2 would be the command failing
    [ "$rc" -le 1 ] || { echo "check --format $f testdata/$model exited $rc"; exit 1; }
  done
  args+=(--json "$dir/$model.json" --sarif "$dir/$model.sarif" "$dir/sarif-schema-2.1.0.json"
    --junit "$dir/$model.junit" "$dir/junit-10.xsd")
done
${PYTHON:-python} scripts/validate_reports.py "${args[@]}"
