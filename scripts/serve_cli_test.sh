#!/usr/bin/env bash
# serve through the command, on the synthetic compare model, no schema needed: values, get and
# list asked of a server print what they print reading the files; a file written is read again; a
# file that cannot be read is said (exit 2) and the server goes on; --reload, --stop; one server a
# socket; nothing left running.
#
#   scripts/serve_cli_test.sh [path to the arxmodel binary]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$(realpath "${1:-$root/bin/arxmodel}")
work=$(mktemp -d)
cd "$work"
cleanup() {
	"$bin" serve --socket s.sock --stop > /dev/null 2>&1 || true
	cd / && rm -rf "$work"
}
trap cleanup EXIT
unset ARXMODEL_SCHEMA_DIR
export XDG_CONFIG_HOME="$work/config"
fail() { echo "FAIL: $*" >&2; exit 1; }
cp "$root/testdata/compare/base.arxml" m.arxml
sleep 1.1 # written a second before the server reads it: not racy (a file written in that second is
          # read again on the first request, as it may have changed after it was read)

"$bin" serve --socket s.sock m.arxml > serve.log 2>&1 &
server=$!
for _ in $(seq 1 200); do [[ -S s.sock ]] && break; sleep 0.05; done
[[ -S s.sock ]] || { cat serve.log; fail 'no server socket'; }

# the same output as the command reading the files
for q in "values /Body/**" "get /Body/LampCfg" "list LAMP"; do
	read -r cmd arg <<< "$q"
	"$bin" "$cmd" "$arg" m.arxml > direct.txt 2> /dev/null
	"$bin" "$cmd" --socket s.sock "$arg" > served.txt 2> served.log
	cmp -s direct.txt served.txt || { diff direct.txt served.txt; fail "$cmd through the server differs"; }
	! grep -q 'read again' served.log || fail "$cmd read the files again with nothing changed"
done

# a file written: read again, the new value
sed -i 's|<VALUE>10</VALUE>|<VALUE>12</VALUE>|' m.arxml
"$bin" values --socket s.sock '/**/Dim' > dim.txt 2> dim.log
[[ "$(cat dim.txt)" == '/Body/LampCfg/Dim = "12"' ]] || { cat dim.txt dim.log; fail 'a written file not read again'; }
grep -q 'read again: 1 file changed' dim.log || { cat dim.log; fail 'reading again not said'; }

# a file that cannot be read: said, exit 2; the server answers again once it can
cp m.arxml good.arxml.bak
echo '<MODEL><broken' > m.arxml
set +e
"$bin" values --socket s.sock '/**/Dim' > /dev/null 2> broken.log
[[ $? == 2 ]] && grep -q 'cannot be read now' broken.log && grep -q 'not closed' broken.log \
	|| { cat broken.log; fail 'a broken file not said'; }
set -e
cp good.arxml.bak m.arxml
"$bin" values --socket s.sock '/**/Dim' > dim2.txt 2> /dev/null || fail 'no answer after the file was mended'
[[ "$(cat dim2.txt)" == '/Body/LampCfg/Dim = "12"' ]] || { cat dim2.txt; fail 'wrong answer after the file was mended'; }

# a client that connects and says nothing holds no one else up
python3 -c 'import socket, time; s = socket.socket(socket.AF_UNIX); s.connect("s.sock"); time.sleep(12)' &
silent=$!
sleep 0.3
start=$(date +%s)
timeout 20 "$bin" values --socket s.sock '/**/Dim' > /dev/null 2>&1 || fail 'a silent client held the server up'
(( $(date +%s) - start < 10 )) || fail 'a silent client held the server up past the request timeout'
kill $silent 2> /dev/null || true

# a client that asks and does not read its answer holds no one up either: a model with an answer
# larger than the socket's buffer, its own server
python3 - > big.arxml <<'PY'
print('<MODEL><PACKAGES><PACKAGE><SHORT-NAME>Big</SHORT-NAME><ELEMENTS><MODULE-VALUES><SHORT-NAME>Cfg</SHORT-NAME><PARAMETERS>')
for k in range(40000):
    print(f'<NUMBER-PARAM-VALUE><DEFINITION-REF>/Defs/Cfg/Long_parameter_name_{k:06d}</DEFINITION-REF><VALUE>{k}</VALUE></NUMBER-PARAM-VALUE>')
print('</PARAMETERS></MODULE-VALUES></ELEMENTS></PACKAGE></PACKAGES></MODEL>')
PY
sleep 1.1
"$bin" serve --socket b.sock big.arxml > big.log 2>&1 &
for _ in $(seq 1 200); do [[ -S b.sock ]] && break; sleep 0.05; done
python3 -c 'import socket, time; s = socket.socket(socket.AF_UNIX); s.connect("b.sock"); s.sendall(b"values\t/**\n"); time.sleep(25)' &
reader=$!
sleep 1
start=$(date +%s)
timeout 40 "$bin" values --socket b.sock '/Big/Cfg/Long_parameter_name_000001' > /dev/null 2>&1 || fail 'a client not reading held the server up'
(( $(date +%s) - start < 20 )) || fail 'a client not reading held the server up past the answer deadline'
kill $reader 2> /dev/null || true
"$bin" serve --socket b.sock --stop > /dev/null 2>&1

# the socket is its owner's only; the worker's is not beside it
[[ $(stat -c %a s.sock) == 600 ]] || fail "socket mode $(stat -c %a s.sock)"
! ls s.sock.* > /dev/null 2>&1 || fail 'a worker socket beside the server socket'
pgrep -P "$server" > /dev/null || fail 'no worker under the server'

# model options with --socket: refused, the server reads by its own
set +e
"$bin" values --socket s.sock --policy automat '/**/Dim' > /dev/null 2> opt.log
[[ $? == 2 ]] && grep -q 'takes no --policy' opt.log || { cat opt.log; fail 'a model option with --socket'; }
set -e

# a file at the socket path of another server is not removed
echo keep > notasocket
set +e
"$bin" serve --socket notasocket m.arxml > /dev/null 2> nosock.log
[[ $? == 2 ]] && grep -q 'is no socket' nosock.log || { cat nosock.log; fail 'a file at --socket'; }
set -e
[[ "$(cat notasocket)" == keep ]] || fail 'a file at --socket was removed'

# a file dated ahead (another machine's clock): read once, not again on every request
mkdir -p ahead && cp m.arxml ahead/a.arxml && touch -d '+1 day' ahead/a.arxml
"$bin" serve --socket a.sock ahead > ahead.log 2>&1 &
for _ in $(seq 1 200); do [[ -S a.sock ]] && break; sleep 0.05; done
"$bin" values --socket a.sock '/**/Dim' > /dev/null 2> ahead1.log
"$bin" values --socket a.sock '/**/Dim' > /dev/null 2> ahead2.log
! grep -q 'read again' ahead2.log || { cat ahead2.log; fail 'a future-dated file read again on every request'; }
"$bin" serve --socket a.sock --stop > /dev/null 2>&1

# an empty set whose directory goes: said (exit 2), not answered as empty
mkdir -p empty
"$bin" serve --socket e.sock empty > empty.log 2>&1 &
for _ in $(seq 1 200); do [[ -S e.sock ]] && break; sleep 0.05; done
[[ -S e.sock ]] || { cat empty.log; fail 'no server on an empty directory'; }
rmdir empty
set +e
"$bin" values --socket e.sock '/**' > /dev/null 2> gone_set.log
[[ $? == 2 ]] || { cat gone_set.log; fail 'an input directory gone answered as before'; }
set -e
"$bin" serve --socket e.sock --stop > /dev/null 2>&1

# a server killed outright: its worker stops and removes its socket and directory
"$bin" serve --socket k.sock m.arxml > killed.log 2>&1 &
killed=$!
for _ in $(seq 1 200); do [[ -S k.sock ]] && break; sleep 0.05; done
dirs_before=$(ls -d "${TMPDIR:-/tmp}"/arxmodel-"$killed"-* 2> /dev/null | wc -l)
[[ $dirs_before == 1 ]] || fail "no worker directory for the server ($dirs_before)"
kill -9 "$killed"
for _ in $(seq 1 160); do ls -d "${TMPDIR:-/tmp}"/arxmodel-"$killed"-* > /dev/null 2>&1 || break; sleep 0.1; done
! ls -d "${TMPDIR:-/tmp}"/arxmodel-"$killed"-* > /dev/null 2>&1 || fail 'an orphaned worker left its directory'
rm -f k.sock

# --idle takes a whole number; a server that cannot start leaves no directory behind
set +e
timeout 10 "$bin" serve --socket x.sock --idle 6O m.arxml > /dev/null 2> idle.log
[[ $? == 2 ]] && grep -q 'idle takes minutes' idle.log || { cat idle.log; fail '--idle 6O'; }
before=$(ls -d "${TMPDIR:-/tmp}"/arxmodel-* 2> /dev/null | wc -l)
echo '<MODEL><broken' > broken.arxml
timeout 20 "$bin" serve --socket x.sock broken.arxml > /dev/null 2>&1
[[ $? == 2 ]] || fail 'a server on a broken file started'
[[ $(ls -d "${TMPDIR:-/tmp}"/arxmodel-* 2> /dev/null | wc -l) == "$before" ]] || fail 'a failed start left its directory'
set -e

# --reload; a second server at the socket; asking with files
"$bin" serve --socket s.sock --reload 2> reload.log || { cat reload.log; fail '--reload'; }
grep -q 'read again: ' reload.log || { cat reload.log; fail '--reload not said'; }
set +e
"$bin" serve --socket s.sock m.arxml > /dev/null 2> second.log
[[ $? == 2 ]] && grep -q 'answers at s.sock already' second.log || { cat second.log; fail 'a second server at the socket'; }
"$bin" values --socket s.sock '/**/Dim' m.arxml > /dev/null 2>&1
[[ $? == 2 ]] || fail 'values --socket with files'
set -e

# --stop, whatever the configuration says now: the server and its worker gone, the socket removed
mkdir -p "$XDG_CONFIG_HOME/arxmodel" && echo 'schema_dir = [' > "$XDG_CONFIG_HOME/arxmodel/config.toml"
"$bin" serve --socket s.sock --stop 2> stop.log || { cat stop.log; fail '--stop'; }
for _ in $(seq 1 100); do [[ -e s.sock ]] || break; sleep 0.05; done
[[ ! -e s.sock ]] || fail 'socket left after --stop'
sleep 0.2
! kill -0 "$server" 2> /dev/null || fail 'the server still running'
! pgrep -P "$server" > /dev/null || fail 'a worker left running'
set +e
"$bin" values --socket s.sock '/**/Dim' > /dev/null 2> gone.log
[[ $? == 2 ]] && grep -q 'no server at s.sock' gone.log || { cat gone.log; fail 'asking a stopped server'; }
set -e
echo 'serve CLI test: ok'
