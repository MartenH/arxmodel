module main

import arxmodel
import flatxml
import os

// The commands comparing versions of a model (diff, merge3) and git's drivers for them.
//
// Exit codes, stable for scripts and git: diff 0 when the versions are the same model, 1 when
// they differ; merge3 0 when the merge is clean, 1 when it has conflicts (the result is written,
// holding ours there); 2 for anything that kept the command from answering (a bad option, a file
// not read, no rules).

const exit_trouble = 2

// read_version loads one version, a file or a directory; /dev/null (git's side of an added or a
// removed file) is an empty one.
fn read_version(o Opts, path string) !&arxmodel.Model {
	if path == '/dev/null' {
		return arxmodel.empty_model()
	}
	m := arxmodel.load([path], jobs: o.jobs)!
	if m.failed.len > 0 {
		return error(m.failed.map('not read: ${it.msg}').join('; '))
	}
	return m
}

// versions loads versions and the ruling to read them by; the rules line on standard error unless
// quiet.
fn versions(o Opts, paths []string, quiet bool) !(arxmodel.Ruling, []arxmodel.Version) {
	mut models := []&arxmodel.Model{}
	for p in paths {
		models << read_version(o, p)!
	}
	ch := choose(o, models, load_policy(o))!
	if !quiet {
		eprintln(rules_line(o, ch.name))
	}
	r := ch.ruling(models, check_options(o))
	mut vs := []arxmodel.Version{}
	for m in models {
		vs << r.read(m)!
	}
	return r, vs
}

fn trouble(msg string) {
	eprintln(msg)
	exit(exit_trouble)
}

// cmd_diff prints what changed from version A to version B, by AUTOSAR path.
fn cmd_diff(o Opts) {
	if o.paths.len != 2 {
		trouble('diff takes two versions, A and B (files or directories)')
	}
	r, v := versions(o, o.paths, false) or {
		trouble(err.msg())
		return
	}
	changes := r.diff(&v[0], &v[1])
	for c in changes {
		println(c.line())
	}
	eprintln(plural(changes.len, 'change'))
	exit(if changes.len > 0 { 1 } else { 0 })
}

// cmd_merge3 merges OURS and THEIRS, two changed versions of BASE, and writes the result: to OUT
// (a file for a file, a directory for a directory, - for standard output), each document of the
// base as the merge leaves it. Conflicts are printed by AUTOSAR path on standard error.
fn cmd_merge3(o Opts) {
	if o.paths.len != 3 {
		trouble('merge3 takes three versions: BASE OURS THEIRS (files or directories)')
	}
	set := os.is_dir(o.paths[0])
	out := if o.out == '' { '-' } else { o.out }
	if set && out == '-' {
		trouble('merge3 of directories needs -o DIR')
	}
	r, v := versions(o, o.paths, false) or {
		trouble(err.msg())
		return
	}
	mut res := r.merge3(&v[0], &v[1], &v[2]) or {
		trouble(err.msg())
		return
	}
	for c in res.conflicts {
		eprintln(c.line())
	}
	mut me := res.m3.edit
	mut written := [out]
	if out == '-' {
		text := me.doc_edit(0).xml()
		print(text)
		// the result checked from a copy
		tmp := os.join_path(os.temp_dir(), 'arxmodel_merge3_${os.getpid()}.arxml')
		os.write_file(tmp, text) or { trouble('${tmp}: ${err.msg()}') }
		written = [tmp]
	} else if set {
		root := os.real_path(o.paths[0])
		me.write_to(fn [root, out] (d &flatxml.Doc) string {
			return os.join_path(out, os.real_path(d.path).all_after(root + os.path_separator))
		}) or { trouble('${out}: ${err.msg()}') }
	} else {
		me.write_to(fn [out] (d &flatxml.Doc) string {
			return out
		}) or { trouble('${out}: ${err.msg()}') }
	}
	validate_result(o, written)
	if out == '-' {
		os.rm(written[0]) or {}
	}
	eprintln('${plural(res.m3.ours.changes.len, 'change')} of ours, ${plural(res.m3.taken, 'change')} of theirs taken; ${plural(res.conflicts.len, 'conflict')}')
	exit(if res.conflicts.len > 0 { 1 } else { 0 })
}

// cmd_git_diff is git's external diff driver: git passes the path and, for each side, a file, its
// hash and its mode (`path old-file old-hex old-mode new-file new-hex new-mode`), and for a rename
// or a copy the new path and git's header for it. It always exits 0, since anything else makes
// git abort the whole diff: a file that cannot be read as a model gets a plain text diff.
fn cmd_git_diff(o Opts) {
	if o.paths.len < 7 {
		// an unmerged path: git passes the path alone
		println('* Unmerged path ${o.paths[0]}')
		return
	}
	path := o.paths[0]
	new_path := if o.paths.len >= 8 { o.paths[7] } else { path }
	println('arxmodel diff a/${path} b/${new_path}')
	if o.paths.len >= 9 {
		for l in o.paths[8].split_into_lines() {
			println(l)
		}
	}
	r, v := versions(o, [o.paths[1], o.paths[4]], true) or {
		println('(not read as a model: ${err.msg()}; a text diff follows)')
		res := os.exec(['git', 'diff', '--no-index', '--no-ext-diff', '--', o.paths[1], o.paths[4]])
		print(res.output)
		exit(0)
	}
	changes := r.diff(&v[0], &v[1])
	for c in changes {
		// the positions name git's temporary files: the path says which file it is
		println(c.line().all_before('  '))
	}
	if changes.len == 0 {
		println('(the same model)')
	}
}

// cmd_git_setup sets up git's drivers in a repository: merge=arxml and diff=arxml for *.arxml in
// .gitattributes, and the drivers in the repository's configuration, calling this binary with
// the rules options given. A schema directory given is made into a rules file (in the
// repository's git directory, never committed), so the drivers do not compile the schema for every
// file; with no option, the drivers read by what is configured where they run (the schema
// directory of the environment or the user's configuration, else the built-in rules, as in CI).
fn cmd_git_setup(o Opts) {
	check_rule_options(o) or { trouble(err.msg()) }
	repo := if o.paths.len > 0 { o.paths[0] } else { '.' }
	top := git_out(repo, ['rev-parse', '--show-toplevel']) or {
		trouble(err.msg())
		return
	}
	mut rules := ''
	if o.no_schema {
		rules = '--no-schema'
	} else if o.rules_file != '' {
		rules = '--rules ${os.quoted_path(os.real_path(o.rules_file))}'
	} else if o.schema_dir != '' {
		rules = setup_rules_file(o, repo, top)
	}
	if o.policy != '' {
		rules += ' --policy ${os.quoted_path(os.real_path(o.policy))}'
	}
	cmd := os.quoted_path(os.real_path(os.executable()))
	for key, value in {
		'merge.arxml.name':   'arxmodel three-way merge of AUTOSAR models'
		'merge.arxml.driver': '${cmd} merge3 ${rules} %O %A %B -o %A'.replace('  ', ' ')
		'diff.arxml.command': '${cmd} git-diff ${rules}'.trim_space()
	} {
		git_out(repo, ['config', key, value]) or { trouble('git config ${key}: ${err.msg()}') }
		println('${key} = ${value}')
	}
	attrs := os.join_path(top, '.gitattributes')
	line := '*.arxml merge=arxml diff=arxml'
	have := os.read_file(attrs) or { '' }
	if have.split_into_lines().any(it.trim_space() == line) {
		println('${attrs}: has ${line}')
		return
	}
	sep := if have == '' || have.ends_with('\n') { '' } else { '\n' }
	os.write_file(attrs, have + sep + line + '\n') or { trouble('${attrs}: ${err.msg()}') }
	println('${attrs}: added ${line}')
}

// setup_rules_file makes the rules of the schema the repository's models declare into a rules
// file in its git directory, and is the option naming it; a repository with no model yet keeps
// the schema directory.
fn setup_rules_file(o Opts, repo string, top string) string {
	dir := '--schema-dir ${os.quoted_path(os.real_path(o.schema_dir))}'
	listed := git_out(repo, ['ls-files', '--', '*.arxml', '*.ARXML']) or { return dir }
	files := listed.split_into_lines().filter(it != '').map(os.join_path(top, it))
	if files.len == 0 {
		println('no .arxml file in the repository yet: the drivers compile the schema from ${o.schema_dir}')
		return dir
	}
	m := arxmodel.load(files, jobs: o.jobs) or { return dir }
	sc := arxmodel.compile_schemas(m, o.schema_dir, policy: load_policy(o))
	gitdir := git_out(repo, ['rev-parse', '--absolute-git-dir']) or { return dir }
	path := os.join_path(gitdir, 'arxmodel', 'autosar.rules.txt')
	os.mkdir_all(os.dir(path)) or { trouble('${path}: ${err.msg()}') }
	emit_rules(Out{}, &sc, path)
	return '--rules ${os.quoted_path(path)}'
}

fn git_out(repo string, args []string) !string {
	mut all := ['git', '-C', repo]
	all << args
	res := os.exec(all)
	if res.exit_code != 0 {
		return error(res.output.trim_space())
	}
	return res.output.trim_space()
}

// validate_result checks a merge's result by the rules chosen as check would: with the built-in
// rules or a rules file, the layers that need no schema (the merge, references); with a schema,
// every layer. What it finds is said on standard error; it does not change the exit code, which
// says whether the merge itself was clean.
fn validate_result(o Opts, paths []string) {
	m := arxmodel.load(paths, jobs: o.jobs) or {
		eprintln('the result: ${err.msg()}')
		return
	}
	policy := load_policy(o)
	ch := choose(o, [m], policy) or {
		eprintln('the result was not checked: ${err.msg()}')
		return
	}
	c := check_by(&ch, m, policy, check_options(o)) or {
		eprintln('the result was not checked: ${err.msg()}')
		return
	}
	layers := if ch.typing != unsafe { nil } { 'every layer' } else { 'the merge and references' }
	errors := c.findings.filter(it.severity == .error)
	eprintln('the result, checked (${layers}): ${plural(errors.len, 'error')}, ${plural(c.count(.warning), 'warning')}')
	for f in errors#[..20] {
		eprintln('  ${f}')
	}
}
