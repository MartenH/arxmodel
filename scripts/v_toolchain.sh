# Install the PINNED V toolchain: V's source at .v-version, and its C bootstrap (vlang/vc) at
# .vc-version, a vc commit proven to build that V. `make` clones vc unpinned by default, so
# pinning only the source is not a pin. Sourced by .github/actions/setup-v.
#
# A build is trusted only with BOTH kinds of evidence: the two trees are at their pins, and a
# stamp, written after `make` succeeded, names exactly those pins. A failed `make` leaves the
# trees at their pins and the previous binary in place, so the trees alone prove nothing; the
# stamp is untracked, so a checkout can move the trees under it, so the stamp alone proves
# nothing either.

# v_toolchain_stamp_path <vdir> — where the success stamp lives (inside the checkout, so
# deleting the checkout deletes the claim).
v_toolchain_stamp_path() {
	printf '%s\n' "$1/.arxmodel_built_from"
}

# v_toolchain_want_stamp <v_pin> <vc_pin> — the stamp these pins ask for.
v_toolchain_want_stamp() {
	printf '%s %s\n' "$1" "$2"
}

# v_toolchain_build_reason <vdir> <v_pin> <vc_pin> — why a build is needed (missing, notgit,
# stale), or an empty line if the toolchain there is the one the pins name.
v_toolchain_build_reason() {
	vdir=$1
	v_pin=$2
	vc_pin=$3
	if [ ! -x "$vdir/v" ]; then
		printf 'missing\n'
		return 0
	fi
	if ! git -C "$vdir" rev-parse --git-dir >/dev/null 2>&1; then
		printf 'notgit\n'
		return 0
	fi
	if [ "$(git -C "$vdir" rev-parse HEAD 2>/dev/null || true)" != "$v_pin" ]; then
		printf 'stale\n'
		return 0
	fi
	if [ "$(git -C "$vdir/vc" rev-parse HEAD 2>/dev/null || true)" != "$vc_pin" ]; then
		printf 'stale\n'
		return 0
	fi
	want=$(v_toolchain_want_stamp "$v_pin" "$vc_pin")
	have=$(cat "$(v_toolchain_stamp_path "$vdir")" 2>/dev/null || true)
	if [ "$have" != "$want" ]; then
		printf 'stale\n'
		return 0
	fi
	printf '\n'
}

# v_toolchain_fetch_pin <dir> <url> <sha> — put <dir> at <sha>, fetched by URL so no remote is
# configured or changed.
v_toolchain_fetch_pin() {
	dir=$1
	url=$2
	sha=$3
	if [ ! -e "$dir/.git" ]; then
		git init -q "$dir"
	fi
	git -C "$dir" fetch -q --depth=1 "$url" "$sha"
	git -C "$dir" checkout -q FETCH_HEAD
}

# v_toolchain_install <vdir> <v_pin> <vc_pin> — fetch both pins and build; the stamp is written
# last, so a failed build leaves none.
v_toolchain_install() {
	vdir=$1
	v_pin=$2
	vc_pin=$3
	rm -f "$(v_toolchain_stamp_path "$vdir")"
	v_toolchain_fetch_pin "$vdir" https://github.com/vlang/v "$v_pin"
	v_toolchain_fetch_pin "$vdir/vc" https://github.com/vlang/vc "$vc_pin"
	# tcc first and without local=1, which would also turn off latest_tcc; V needs the libgc.a
	# that tcc's tree carries.
	make -C "$vdir" latest_tcc
	# local=1 stops make from pulling vc (or anything else) out from under the pinned bootstrap.
	make -C "$vdir" local=1
	v_toolchain_want_stamp "$v_pin" "$vc_pin" > "$(v_toolchain_stamp_path "$vdir")"
}
