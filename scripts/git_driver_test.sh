#!/usr/bin/env bash
# Runs real git merges through arxmodel's merge driver, with no schema anywhere: two branches
# editing one synthetic .arxml. Disjoint edits merge cleanly; overlapping edits leave a conflict
# and a non-zero exit. The diff driver names the change by AUTOSAR path.
#
#   scripts/git_driver_test.sh [path to the arxmodel binary]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$(realpath "${1:-$root/bin/arxmodel}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# no schema configured: the built-in identity rules
unset ARXMODEL_SCHEMA_DIR
export XDG_CONFIG_HOME="$work/config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$work/repo"
git init -q -b main "$repo"
cd "$repo"
git config user.name test
git config user.email test@example.invalid
cp "$root/testdata/compare/base.arxml" model.arxml
"$bin" git-setup . > /dev/null
grep -qx '\*.arxml merge=arxml diff=arxml' .gitattributes || fail 'no .gitattributes line'
git add -A && git commit -qm base

watts() { # the watts of a lamp in model.arxml
	awk -v lamp="$1" '/<SHORT-NAME>/{n=$0} /<WATTS>/{ if (index(n, ">" lamp "<")) { gsub(/[^0-9]/, ""); print; exit } }' model.arxml
}

# disjoint: one branch edits Head, the other Tail and a parameter value
git checkout -qb head
sed -i 's|<WATTS>55</WATTS>|<WATTS>60</WATTS>|' model.arxml
git commit -qam 'head 60'
git checkout -q main
sed -i 's|<WATTS>5</WATTS>|<WATTS>7</WATTS>|; s|<VALUE>10</VALUE>|<VALUE>12</VALUE>|' model.arxml
git commit -qam 'tail 7'
git merge -q --no-edit head > "$work/clean.log" 2>&1 || { cat "$work/clean.log"; fail 'disjoint edits did not merge'; }
[ "$(watts Head)" = 60 ] && [ "$(watts Tail)" = 7 ] || fail "merged: Head $(watts Head), Tail $(watts Tail)"
grep -q '<VALUE>12</VALUE>' model.arxml || fail 'the parameter value was lost'

# the diff driver: the change by AUTOSAR path
git diff HEAD~1 HEAD -- model.arxml > "$work/diff.txt"
grep -q '^~ /Body/Head#WATTS: "55" -> "60"' "$work/diff.txt" || { cat "$work/diff.txt"; fail 'diff driver'; }

# overlapping: both branches edit Head
git checkout -qb other
sed -i 's|<WATTS>60</WATTS>|<WATTS>65</WATTS>|' model.arxml
git commit -qam 'head 65'
git checkout -q main
sed -i 's|<WATTS>60</WATTS>|<WATTS>70</WATTS>|' model.arxml
git commit -qam 'head 70'
if git merge -q --no-edit other > "$work/conflict.log" 2>&1; then
	fail 'overlapping edits merged without a conflict'
fi
grep -q '! /Body/Head#WATTS' "$work/conflict.log" || { cat "$work/conflict.log"; fail 'the conflict is not named'; }
git status --porcelain | grep -q '^UU model.arxml' || fail 'model.arxml is not left unmerged'
[ "$(watts Head)" = 70 ] || fail "the conflicted file does not hold ours: $(watts Head)"
git merge --abort

# the diff driver: no rules line in its output; a rename names both paths; a file that is not a
# model gets a text diff, and the driver still exits 0
git mv model.arxml renamed.arxml
sed -i 's|<WATTS>7</WATTS>|<WATTS>8</WATTS>|' renamed.arxml
git commit -qam 'rename and edit'
git diff -M HEAD~1 HEAD > "$work/rename.txt" 2>&1 || fail 'diff of a rename'
grep -q '^arxmodel diff a/model.arxml b/renamed.arxml' "$work/rename.txt" || { cat "$work/rename.txt"; fail 'rename not shown'; }
grep -q '^~ /Body/Tail#WATTS: "7" -> "8"' "$work/rename.txt" || { cat "$work/rename.txt"; fail 'rename diff'; }
! grep -q '^rules:' "$work/rename.txt" || fail 'a rules line in the diff output'
printf '<broken>' > renamed.arxml
git diff > "$work/broken.txt" 2>&1 || fail 'the diff driver failed on a broken file'
grep -q 'not read as a model' "$work/broken.txt" || { cat "$work/broken.txt"; fail 'no fallback note'; }
grep -q '^+<broken>' "$work/broken.txt" || { cat "$work/broken.txt"; fail 'no text diff'; }
git checkout -q -- renamed.arxml

# rules options are checked as everywhere: contradicting ones are refused
if "$bin" git-setup --no-schema --rules x.rules.txt . > /dev/null 2>&1; then fail 'git-setup took --no-schema with --rules'; fi
# a rules file that cannot be read is said, not skipped
if "$bin" merge3 --rules "$work/none.rules.txt" renamed.arxml renamed.arxml renamed.arxml > /dev/null 2> "$work/norules.txt"; then
	fail 'merge3 with an unreadable rules file'
fi
grep -q 'none.rules.txt' "$work/norules.txt" || fail 'the unreadable rules file is not named'

# a schema directory given to git-setup becomes a rules file in the git directory
lib="$work/lib"
git init -q -b main "$lib"
cp "$root/testdata/model/a.arxml" "$lib/a.arxml"
git -C "$lib" add a.arxml
"$bin" git-setup --schema-dir "$root/testdata/schemas" "$lib" > "$work/setup.txt"
grep -q "merge.arxml.driver = .* merge3 --rules '\?$lib/.git/arxmodel/autosar.rules.txt'\? %O %A %B -o %A" "$work/setup.txt" || { cat "$work/setup.txt"; fail 'git-setup did not record the rules file'; }
[ -f "$lib/.git/arxmodel/autosar.rules.txt" ] || fail 'no rules file emitted'
echo 'git driver test: ok'
