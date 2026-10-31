#!/usr/bin/env bash
# merge3 through the command: its JSON report, and decisions taken back with --resolve. Two
# conflicts on the synthetic model; no schema needed.
#
# usage: scripts/merge3_cli_test.sh ARXMODEL
set -euo pipefail
bin=$(realpath "$1")
base=$(realpath testdata/compare/base.arxml)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
fail() { echo "merge3_cli_test: $*" >&2; exit 1; }

sed -e 's|<WATTS>55</WATTS>|<WATTS>60</WATTS>|' -e 's|<WATTS>5</WATTS>|<WATTS>6</WATTS>|' "$base" > ours.arxml
sed -e 's|<WATTS>55</WATTS>|<WATTS>65</WATTS>|' -e 's|<WATTS>5</WATTS>|<WATTS>7</WATTS>|' "$base" > theirs.arxml
ids() { grep -o '"id":"[0-9a-f]*"' "$1" | cut -d'"' -f4; }

# the report goes where the result does not, so it needs -o
if "$bin" merge3 --no-schema --format json "$base" ours.arxml theirs.arxml > /dev/null 2>&1; then
	fail 'merge3 --format json without -o'
fi
if "$bin" merge3 --no-schema --format junit "$base" ours.arxml theirs.arxml -o out.arxml > /dev/null 2>&1; then
	fail 'merge3 --format junit'
fi

rc=0
"$bin" merge3 --no-schema --format json "$base" ours.arxml theirs.arxml -o out.arxml > report.json 2> report.log || rc=$?
[ "$rc" -eq 1 ] || fail "two conflicts exited $rc"
grep -q '"conflicts":2' report.json || { cat report.json; fail 'the report does not count two conflicts'; }
grep -q '"value":"60"' report.json && grep -q '"value":"65"' report.json || fail 'the report lacks the sides'
# the context is the element as the file has it, on its lines
grep -q 'UUID=\\"u1\\">\\n          <SHORT-NAME>' report.json || fail 'the context is not the source'
grep -q '^! ' report.log && fail 'the conflicts went to standard error too'
first=$(ids report.json | sed -n 1p)
second=$(ids report.json | sed -n 2p)

# the same versions under other names give the same ids
mkdir elsewhere
cp ours.arxml elsewhere/a.arxml
cp theirs.arxml elsewhere/b.arxml
"$bin" merge3 --no-schema --format json "$base" elsewhere/a.arxml elsewhere/b.arxml -o out2.arxml > again.json 2> /dev/null || true
[ "$(ids again.json)" = "$(ids report.json)" ] || fail 'the ids depend on the files'

# one decided: the other is still a conflict, and the result holds what was decided
{ echo '# a comment'; echo "theirs $first  # with one after it"; echo; } > one.txt
rc=0
"$bin" merge3 --no-schema --resolve one.txt "$base" ours.arxml theirs.arxml -o one.arxml 2> one.log || rc=$?
[ "$rc" -eq 1 ] || { cat one.log; fail "one decided of two exited $rc"; }
grep -q '<WATTS>65</WATTS>' one.arxml || fail 'theirs not taken'
grep -q '<WATTS>6</WATTS>' one.arxml || fail 'ours not kept at the other'
grep -q '1 conflict, 1 resolved' one.log || { cat one.log; fail 'the counts'; }

# both decided: exit 0
printf 'theirs %s\nours %s\n' "$first" "$second" > both.txt
"$bin" merge3 --no-schema --resolve both.txt "$base" ours.arxml theirs.arxml -o both.arxml 2> both.log || { cat both.log; fail 'all decided is not clean'; }
grep -q '<WATTS>65</WATTS>' both.arxml && grep -q '<WATTS>6</WATTS>' both.arxml || fail 'both decided'

# a side changed: the decision no longer applies, and says so
sed -e 's|<WATTS>65</WATTS>|<WATTS>70</WATTS>|' theirs.arxml > later.arxml
rc=0
"$bin" merge3 --no-schema --format json --resolve both.txt "$base" ours.arxml later.arxml -o later_out.arxml > later.json 2> later.log || rc=$?
[ "$rc" -eq 1 ] || fail "a changed conflict exited $rc"
grep -q "warning: decision $first met no conflict" later.log || { cat later.log; fail 'an unused decision not said'; }
grep -q "\"unused\":\\[\"$first\"\\]" later.json || { cat later.json; fail 'an unused decision not reported'; }
grep -q '<WATTS>60</WATTS>' later_out.arxml || fail 'a stale decision was applied'

# a bad file stops it
echo 'both 123' > bad.txt
rc=0
"$bin" merge3 --no-schema --resolve bad.txt "$base" ours.arxml theirs.arxml -o bad.arxml 2> bad.log || rc=$?
[ "$rc" -eq 2 ] || fail "a bad decisions file exited $rc"
grep -q 'bad.txt: line 1' bad.log || { cat bad.log; fail 'where the file is bad'; }
[ ! -e bad.arxml ] || fail 'a result from a bad decisions file'
echo 'merge3_cli_test: ok'
