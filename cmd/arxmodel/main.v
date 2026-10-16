// arxmodel — command-line access to AUTOSAR models.
//
//   arxmodel load [--jobs N] <file|dir>...    read every .arxml into one set, print what it holds
//   arxmodel rules --schema-dir DIR [--jobs N] [--problems] [--dump FILE] <file|dir>...
//                                              read them, find and compile the schemas they
//                                              declare, and print the merge rules each gives
//   arxmodel rules --schema-dir DIR --emit FILE <file|dir>...
//                                              write the merge rules of the governing schema
//                                              as flatxml rule text
//   arxmodel check (--schema-dir DIR | --rules FILE) [--all] [--case-sensitive]
//                  [--ignore-attr NAME]... [--check-attr NAME]... [--skip-xml]
//                  [--skip-multiplicity] [--skip-references] [--refs-from <file|dir>]...
//                  [--jobs N] <file|dir>...
//                                              merge the files by the rules of the governing
//                                              schema (or a rules file) and check them in four
//                                              layers: the merge, each file against its XML
//                                              schema, the merged model's multiplicities, its
//                                              references
//   arxmodel get (--schema-dir DIR | --rules FILE) <path> <file|dir>...
//   arxmodel list (--schema-dir DIR | --rules FILE) <ELEMENT> <file|dir>...
//                                              the merged element at an AUTOSAR path; the paths
//                                              of every referrable element of a name
//   arxmodel merge (--schema-dir DIR | --rules FILE) [the options of check] [--force]
//                  -o OUT|- <file|dir>...      merge and check them as check does (the summary
//                                              on standard error), and write the merged model
//                                              as one document: not where check finds errors,
//                                              unless --force
//
//   arxmodel diff (--schema-dir DIR | --rules FILE) A B
//   arxmodel merge3 (--schema-dir DIR | --rules FILE) BASE OURS THEIRS [-o OUT]
//                                              a semantic diff, and a three-way merge, by
//                                              AUTOSAR path
//   arxmodel git-setup, git-diff                git's merge and diff drivers
//
//   arxmodel policy [--policy NAME|FILE] [--diff NAME|FILE] [--schema [-o FILE]]
//                                              the policy's settings, how two differ, its schema
//
// rules, check and merge take --policy: `spec` (policy.toml, the AUTOSAR specification's, built
// in, the default), `automat` (automat.policy.toml) or a file.
//
// load and rules exit 1 when a file could not be read, or (rules) a schema was not declared, not
// found or did not compile; check exits 1 on findings the policy calls errors (and on files that
// could not be read or declare no schema, or a model no schema governs); what could be done is
// still printed. Every command exits 2 when it cannot run at all (usage, a rules or policy file
// that cannot be read).
//
// check --format json|junit writes its report (arxmodel's JSON, docs/report.md; JUnit XML) to
// standard output and what it read to standard error.
module main

import arxmodel
import os
import strings
import time

const usage = 'usage:
  arxmodel version                             the version (also --version)
  arxmodel load [--jobs N] <file|dir>...
      read every .arxml below the paths into one document set and print what it holds
  arxmodel rules --schema-dir DIR [--jobs N] [--problems] [--dump FILE] <file|dir>...
      also find each declared schema in DIR, compile each once, and print its merge rules;
      --problems lists every annotation that could not be applied, --dump writes the rules
      as tab-separated lines (FILE, or - for standard output, the summary then going to
      standard error)
  arxmodel check --schema-dir DIR [--all] [--case-sensitive] [--ignore-attr NAME]...
                 [--check-attr NAME]... [--skip-xml] [--skip-multiplicity] [--skip-references]
                 [--refs-from <file|dir>]... [--jobs N] <file|dir>...
      merge the files into one model by the rules of the newest declared release (or the newest
      at hand) and check it in four layers: what the merge rules forbid, each file against its
      XML schema (--skip-xml; --jobs threads), the count of each role in the merged model against the
      meta-model (--skip-multiplicity), every reference against the AUTOSAR paths of the model
      (--skip-references; --refs-from loads more files only to resolve references against, such
      as standard or vendor definitions). Each finding is an error, a warning or ignored, as the
      [severity] table of the policy says; the counts by severity and kind are printed, then the errors
      and warnings with every file and line (the first 20 of each kind, or --all); exit 1 on
      errors only. Keys ignore ASCII case unless --case-sensitive; --ignore-attr names an
      attribute whose values may differ between fragments (namespace declarations, xsi
      attributes and UUID may; --check-attr UUID compares it after all)
  arxmodel rules --schema-dir DIR --emit FILE <file|dir>...
      write the merge rules the governing schema gives, as flatxml rule text with a header
      naming the schema; generated from the schema on this machine, never to be committed
  arxmodel check --rules FILE ... <file|dir>...
      merge by a rules file instead of compiling the schema (the merge layer only); warns when
      the files declare a newer release than the file was made from
  arxmodel check ... --format text|json|junit <file|dir>...
      the report as text (the default), JSON (docs/report.md) or JUnit XML on
      standard output, what was read on standard error; exit 0 clean, 1 errors (or files not
      read, declaring no schema, or no schema governing them), 2 when it cannot run
  arxmodel get (--schema-dir DIR | --rules FILE) [--jobs N] <path> <file|dir>...
      the merged element at an AUTOSAR path (/Pkg/Name): its element and every file and line;
      every element holding it, where the merge keeps two apart
  arxmodel list (--schema-dir DIR | --rules FILE) [--jobs N] <ELEMENT-NAME> <file|dir>...
      the AUTOSAR path of every referrable element of that name
  arxmodel merge (--schema-dir DIR | --rules FILE) [the options of check] [--force]
                 -o OUT|- <file|dir>...
      merge and check the files as check does, the summary going to standard error, and write
      the merged model as one ARXML to OUT (- for standard output): what came from one file and
      was not merged into is copied byte for byte, values that differ are those of the first
      file, and the root carries the schema location of the first file that declares the
      governing release. Nothing is written where check would exit 1 (errors, files not read or
      declaring no schema), unless --force
  arxmodel diff (--schema-dir DIR | --rules FILE) A B
      what changed from version A to version B (each a file or a directory), by AUTOSAR path:
      both merged by the same rules (the newest release either declares), so where an element
      is written, the order of items whose order means nothing, and the attributes the merge lets
      differ are not changes. One line a change: - removed, + added, > moved, ~ text, @ attribute.
      Exit 0 when they are the same model, 1 when they differ
  arxmodel merge3 (--schema-dir DIR | --rules FILE) BASE OURS THEIRS [-o OUT]
      merge OURS and THEIRS, two changed versions of BASE (files, or directories), on BASE: every
      byte no change touched kept as BASE has it; written to OUT (a file, or a directory for
      directories; standard output by default for files). Where the sides change one node
      differently, ours is taken and the conflict printed by AUTOSAR path on standard error.
      Exit 0 when clean, 1 on conflicts
  arxmodel git-setup (--schema-dir DIR | --rules FILE) [REPO]
      set up the git merge and diff drivers for *.arxml in a repository (.gitattributes, and the
      configuration of the repository, calling this binary as merge3 and git-diff)
  arxmodel git-diff (--schema-dir DIR | --rules FILE) path old-file old-hex old-mode new-file new-hex new-mode
      the external diff driver of git
  Exit 2, for any command, when something kept it from answering (an option, a file not read)
  arxmodel policy [--policy NAME|FILE] [--diff NAME|FILE] [--schema [-o FILE]]
      every setting of the policy with the values it takes, its value and the specification item
      it concerns, then the severities; --diff, how another policy differs; --schema, the JSON
      Schema of a policy file (policy.schema.json)
  --policy NAME|FILE (rules, check, merge, get, list, diff, merge3, policy): the merge policy:
      spec (policy.toml, as the AUTOSAR specification has it, the default), automat
      (automat.policy.toml), or a file
  <file|dir>...: the input set, for every command reading models: a file; a directory (every
      .arxml below it); a glob (`*`, `?` within a name, `**` any depth; one matching nothing is
      a warning); @FILE (the paths FILE lists, one a line, `#` comments, relative to FILE);
      --exclude GLOB leaves files out; each file once, sorted by path; --verbose lists them all
  --jobs N: threads for loading (and for the XML schema layer of check); 0 for one per CPU, at
      most 8'

struct Opts {
mut:
	jobs       int
	schema_dir string
	problems   bool
	dump       string
	all        bool     // check: every problem, not the first of each kind
	exact      bool     // check: keys compared as written
	ignore     []string // check: attributes whose values may differ between fragments
	exclude    []string // file globs left out of the input set
	verbose    bool     // list every file of the input set
	compare    []string // check: attributes ignored by default that are compared after all
	emit       string   // rules: write the merge rules here
	rules_file string   // check: merge by these rules
	policy     string   // the policy file; '' for the built-in one
	skip_xml   bool     // check: no XML schema layer
	skip_mult  bool     // check: no multiplicity layer
	skip_refs  bool     // check: no reference layer
	refs_from  []string // check: files loaded only to resolve references against
	out        string   // merge: where the merged model is written ('-' for standard output)
	force      bool     // merge: write it whatever the findings
	no_schema  bool     // the built-in identity rules, whatever schema is configured
	schema     bool     // policy: write policy.schema.json
	diff       string   // policy: the policy to compare with
	builtin    bool     // resolved: no schema and no rules file, so the built-in identity rules
	origin     string   // resolved: where the rules come from, for the `rules:` line
	format     string = 'text' // check: how the report is written
	given      []string // the options given, to refuse those the command does not take
	paths      []string
}

// resolve_rules decides what the files are read by: --no-schema forces the built-in identity
// rules; else --rules or --schema-dir; else the schema directory of the environment
// (ARXMODEL_SCHEMA_DIR) or the configuration file; else the built-in rules, which need no schema.
fn resolve_rules(mut o Opts) ! {
	check_rule_options(o)!
	if o.no_schema {
		o.builtin, o.origin = true, '--no-schema'
		return
	}
	if o.rules_file != '' {
		o.origin = '--rules'
		return
	}
	if o.schema_dir != '' {
		o.origin = '--schema-dir'
		return
	}
	dir, origin := arxmodel.configured_schema_dir()!
	if dir != '' {
		o.schema_dir, o.origin = dir, origin
		return
	}
	o.builtin, o.origin = true, 'no schema configured'
}

// check_rule_options refuses rules options that contradict each other.
fn check_rule_options(o Opts) ! {
	if o.schema_dir != '' && o.rules_file != '' {
		return error('--schema-dir and --rules: one or the other')
	}
	if o.no_schema && (o.schema_dir != '' || o.rules_file != '') {
		return error('--no-schema takes neither --schema-dir nor --rules')
	}
}

// rules_line says which rules a command reads by, so a CI log and a local run can be compared.
fn rules_line(o Opts, name string) string {
	if o.builtin {
		return 'rules: built-in identity rules (${o.origin})'
	}
	if o.rules_file != '' {
		return 'rules: rules file ${o.rules_file}, made from ${name}'
	}
	return 'rules: schema ${name} from ${o.schema_dir} (${o.origin})'
}

fn main() {
	args := os.args[1..]
	if args.len < 1 {
		eprintln(usage)
		exit(2)
	}
	if args[0] in ['version', '--version'] {
		println('arxmodel ${arxmodel.version}')
		return
	}
	mut opts := parse_opts(args[1..]) or {
		eprintln(err.msg())
		eprintln(usage)
		exit(2)
	}
	mut allowed := match args[0] {
		'load' { ['--jobs'] }
		'rules' { ['--jobs', '--schema-dir', '--problems', '--dump', '--emit', '--policy'] }
		'check' {
			['--jobs', '--schema-dir', '--rules', '--no-schema', '--all', '--problems',
				'--case-sensitive', '--ignore-attr', '--check-attr', '--policy', '--skip-xml',
				'--skip-multiplicity', '--skip-references', '--refs-from', '--format']
		}
		'get', 'list' { ['--jobs', '--schema-dir', '--rules', '--no-schema', '--policy'] }
		'merge' {
			['--jobs', '--schema-dir', '--rules', '--no-schema', '--all', '--problems',
				'--case-sensitive', '--ignore-attr', '--check-attr', '--policy', '--skip-xml',
				'--skip-multiplicity', '--skip-references', '--refs-from', '--out', '--force']
		}
		'diff', 'merge3', 'git-diff' {
			['--jobs', '--schema-dir', '--rules', '--no-schema', '--policy', '--case-sensitive',
				'--ignore-attr', '--check-attr', '--out']
		}
		'git-setup' { ['--jobs', '--schema-dir', '--rules', '--no-schema', '--policy'] }
		'policy' { ['--policy', '--schema', '--diff', '--out'] }
		else { []string{} }
	}
	// the input set: every command reading models takes excludes, and lists its files
	if args[0] in ['load', 'rules', 'check', 'get', 'list', 'merge', 'diff', 'merge3'] {
		allowed << ['--exclude', '--verbose']
	}
	if opts.paths.len == 0 && args[0] !in ['git-setup', 'policy'] {
		eprintln('no files or directories given')
		eprintln(usage)
		exit(2)
	}
	if opts.out != '' && args[0] in ['diff', 'git-diff'] {
		eprintln('${args[0]} does not take -o')
		exit(2)
	}
	for a in opts.given {
		if a !in allowed {
			eprintln('${args[0]} does not take ${a}')
			exit(2)
		}
	}
	if args[0] in ['check', 'merge', 'get', 'list', 'diff', 'merge3', 'git-diff', 'git-setup']
		&& opts.schema_dir != '' && opts.rules_file != '' {
		eprintln('${args[0]} takes --schema-dir or --rules, not both')
		exit(2)
	}
	// git-setup records only what it is given: the drivers resolve the rest when they run
	if args[0] in ['check', 'merge', 'get', 'list', 'diff', 'merge3', 'git-diff', 'rules'] {
		resolve_rules(mut opts) or {
			eprintln(err.msg())
			exit(2)
		}
	}
	match args[0] {
		'load' {
			cmd_load(opts)
		}
		'get' {
			cmd_get(opts)
		}
		'list' {
			cmd_list(opts)
		}
		'check' {
			if opts.format != 'text' && opts.format !in arxmodel.report_formats {
				eprintln('--format is text, json or junit, not ${opts.format}')
				exit(2)
			}
			cmd_check(opts)
		}
		'merge' {
			if opts.out == '' {
				eprintln('merge needs -o OUT (or -o - for standard output)')
				exit(2)
			}
			// against the input sets as expanded: every file read, and the directories they came from
			mut inputs := []string{}
			for paths in [opts.paths, opts.refs_from] {
				if paths.len == 0 {
					continue
				}
				found := arxmodel.find_arxml(paths, exclude: opts.exclude) or {
					eprintln(err.msg())
					exit(2)
				}
				inputs << found.files
				inputs << found.bases
			}
			if why := arxmodel.output_clash(opts.out, inputs) {
				eprintln('merge: ${why}')
				exit(2)
			}
			cmd_merge(opts)
		}
		'diff' {
			cmd_diff(opts)
		}
		'merge3' {
			cmd_merge3(opts)
		}
		'git-diff' {
			cmd_git_diff(opts)
		}
		'git-setup' {
			cmd_git_setup(opts)
		}
		'policy' {
			cmd_policy(opts)
		}
		'rules' {
			if opts.schema_dir == '' {
				eprintln('rules needs a schema directory (--schema-dir, ${arxmodel.schema_dir_env} or schema_dir in ${arxmodel.config_path()})')
				exit(2)
			}
			cmd_rules(opts)
		}
		else {
			eprintln(usage)
			exit(2)
		}
	}
}

fn parse_opts(args []string) !Opts {
	mut o := Opts{}
	mut k := 0
	for k < args.len {
		a := args[k]
		if a.starts_with('--') && a !in o.given {
			o.given << a
		}
		match a {
			'--ignore-attr', '--check-attr', '--exclude' {
				if k + 1 >= args.len {
					return error('${a} needs a value')
				}
				match a {
					'--ignore-attr' { o.ignore << args[k + 1] }
					'--check-attr' { o.compare << args[k + 1] }
					else { o.exclude << args[k + 1] }
				}
				k += 2
				continue
			}
			'--verbose' {
				o.verbose = true
			}
			'--all' {
				o.all = true
			}
			'--case-sensitive' {
				o.exact = true
			}
			'--skip-xml' {
				o.skip_xml = true
			}
			'--skip-multiplicity' {
				o.skip_mult = true
			}
			'--skip-references' {
				o.skip_refs = true
			}
			'--force' {
				o.force = true
			}
			'--no-schema' {
				o.no_schema = true
			}
			'--schema' {
				o.schema = true
			}
			'-o', '--out' {
				if k + 1 >= args.len {
					return error('${a} needs a value')
				}
				o.out = args[k + 1]
				if '--out' !in o.given {
					o.given << '--out'
				}
				k += 2
				continue
			}
			'--jobs', '--schema-dir', '--dump', '--emit', '--rules', '--policy', '--refs-from',
			'--format', '--diff' {
				if k + 1 >= args.len {
					return error('${a} needs a value')
				}
				v := args[k + 1]
				match a {
					'--jobs' { o.jobs = v.int() }
					'--schema-dir' { o.schema_dir = v }
					'--emit' { o.emit = v }
					'--rules' { o.rules_file = v }
					'--policy' { o.policy = v }
					'--refs-from' { o.refs_from << v }
					'--format' { o.format = v }
					'--diff' { o.diff = v }
					else { o.dump = v }
				}
				k += 2
				continue
			}
			'--problems' {
				o.problems = true
			}
			else {
				if a.starts_with('--') {
					return error('unknown option ${a}')
				}
				o.paths << a
			}
		}
		k++
	}
	return o
}

fn load_or_exit(o Opts, out Out) &arxmodel.Model {
	m := arxmodel.load(o.paths, jobs: o.jobs, exclude: o.exclude, grow_heap: true) or {
		eprintln(err.msg())
		exit(1)
	}
	mb := f64(m.bytes) / 1e6
	out.line('${m.files.len} files, ${m.set.docs.len} loaded (${mb:.1f} MB) in ${ms(m.took)}, ${m.failed.len} failed')
	print_files(out, m.files, o.verbose)
	for w in m.warnings {
		out.line('warning: ${w}')
	}
	for f in m.failed {
		out.line('  failed: ${f.msg}')
	}
	return m
}

// print_files lists the input set, in its order: every file with --verbose, else the first and
// last three, so a CI log shows what was loaded.
fn print_files(out Out, files []string, verbose bool) {
	if verbose || files.len <= 6 {
		for f in files {
			out.line('  ${f}')
		}
		return
	}
	for f in files[..3] {
		out.line('  ${f}')
	}
	out.line('  ... ${files.len - 6} more (--verbose lists them)')
	for f in files[files.len - 3..] {
		out.line('  ${f}')
	}
}

fn cmd_load(o Opts) {
	out := Out{}
	m := load_or_exit(o, out)
	sw := time.new_stopwatch()
	elements := m.element_count()
	out.line('${elements} elements, ${m.set.tab.len()} distinct names, ${m.set.tab.uri_count()} namespaces (counted in ${ms(sw.elapsed())})')
	if m.failed.len > 0 {
		exit(1)
	}
}

fn cmd_rules(o Opts) {
	// a dump to standard output leaves it to the dump, and the summary goes to standard error
	out := Out{
		err: o.dump == '-'
	}
	m := load_or_exit(o, out)
	policy := load_policy(o)
	sw := time.new_stopwatch()
	sc := arxmodel.compile_schemas(m, o.schema_dir, policy: policy)
	out.line('${sc.uses.len} schemas declared, found and compiled in ${ms(sw.elapsed())}:')
	for u in sc.uses {
		status := if u.error != '' {
			u.error
		} else {
			'${u.path}, compiled in ${ms(u.took)}${if u.note != '' {
				' (' + u.note + ')'
			} else {
				''
			}}'
		}
		out.line('  ${u.name}: ${plural(u.docs.len, 'file')}; ${status}')
	}
	if sc.undeclared.len > 0 {
		out.line('  ${plural(sc.undeclared.len, 'file')} with no schema declared:')
		mut ks := sc.undeclared.keys()
		ks.sort()
		for k in ks {
			out.line('    ${m.set.docs[k].path}: ${sc.undeclared[k]}')
		}
	}
	for g in sc.governing {
		print_governing(out, m, sc, g, o.problems)
	}
	mut dumped := strings.new_builder(1 << 20)
	for u in sc.uses {
		if u.rules == unsafe { nil } {
			continue
		}
		print_rules(out, u.name, u.rules, o.problems)
		if o.dump != '' {
			dump_rules(mut dumped, u.name, u.rules)
		}
	}
	if o.emit != '' {
		emit_rules(out, sc, o.emit)
	}
	defer {
		if m.failed.len > 0 || sc.undeclared.len > 0 || sc.uses.any(it.error != '')
			|| sc.governing.any(it.use < 0) {
			exit(1)
		}
	}
	if o.dump != '' {
		text := dumped.str()
		if o.dump == '-' {
			print(text)
		} else {
			os.write_file(o.dump, text) or {
				eprintln('${o.dump}: ${err.msg()}')
				exit(1)
			}
		}
	}
}

// print_governing says which schema governs a namespace and why, the releases in order, the
// roles of older schemas it has no rule for, and the elements the documents use that it does not
// declare.
fn print_governing(out Out, m &arxmodel.Model, sc &arxmodel.Schemas, g arxmodel.Governing, problems bool) {
	order := g.ranked.map(sc.uses[it].name).join(' < ')
	out.line('releases declared for ${g.ns}, oldest first: ${order}')
	if g.others.len > 0 {
		out.line('  of other schema families, not ranked against ${g.family}: ${g.others.map(sc.uses[it].name).join(', ')}')
	}
	if g.unranked.len > 0 {
		out.line('  with no release in their names: ${g.unranked.map(sc.uses[it].name).join(', ')}')
	}
	if g.use < 0 {
		out.line('  no schema governs: ${g.note}')
		return
	}
	gov := sc.uses[g.use]
	out.line('  governed by ${gov.name}${if g.note != '' { ' (' + g.note + ')' } else { '' }}')
	for k, u in sc.uses {
		if k == g.use || u.ns != g.ns || u.rules == unsafe { nil } {
			continue
		}
		missing := arxmodel.missing_roles(u.rules, gov.rules)
		out.line('  ${u.name}: ${missing.len} of its ${u.rules.rules.len} roles with no rule in ${gov.name}')
		if problems {
			for x in missing {
				out.line('    ${x}')
			}
		}
	}
	und := arxmodel.undeclared_elements(m, sc, g)
	mut n := 0
	for x in und {
		n += x.count
	}
	out.line('  ${plural(und.len, 'element name')} in the documents not declared by ${gov.name} (${plural(n, 'element')})')
	if problems {
		for x in und {
			out.line('    ${x.name}: ${x.count} in ${plural(x.files, 'file')}, first at ${x.first}')
		}
	}
}

fn print_rules(out Out, name string, rs &arxmodel.RuleSet, problems bool) {
	mut multi, mut wrapped, mut keyed, mut split, mut ordered, mut resolved, mut parts := 0, 0, 0, 0, 0, 0, 0
	mut key_not_split, mut split_no_key, mut unresolved := 0, 0, 0
	for r in rs.rules {
		if r.max > 1 {
			multi++
		}
		if r.wrapper {
			wrapped++
		}
		if r.has_key() {
			keyed++
		}
		if r.splittable {
			split++
		}
		if r.ordered {
			ordered++
		}
		if r.has_key() && !r.splittable {
			key_not_split++
		}
		if r.splittable && !r.has_key() {
			split_no_key++
		}
		for it in r.items {
			parts += r.key_spec.len
			resolved += it.key.len
		}
		unresolved += r.problems.filter(it.kind in ['key role not found',
			'key through a multi-valued role']).len
	}
	out.line('${name}:')
	out.line('  ${rs.rules.len} aggregations (meta-model roles): ${multi} multi-valued, ${wrapped} wrapped; held by ${rs.typed} types (${rs.by_type.len} type and role pairs)')
	out.line('  ${keyed} with a split key, ${split} splittable (${key_not_split} keyed and not splittable, ${split_no_key} splittable without a key), ${ordered} ordered')
	out.line('  split keys: ${parts} key parts over the items, ${unresolved} unresolved (once per item type); ${resolved} key paths')
	c := rs.census
	out.line('  ${c.appinfo} annotations')
	print_counts(out, 'used', c.used)
	print_counts(out, 'checked', c.checked)
	print_counts(out, 'not read', c.not_read)
	print_counts(out, 'other', c.other)
	if c.malformed.len > 0 {
		out.line('    malformed: ${c.malformed.len} (first: "${c.malformed[0]}")')
	}
	print_counts(out, 'notes', c.notes)
	print_counts(out, 'problems', c.problems)
	if problems {
		for r in rs.rules {
			for p in r.problems {
				out.line('    ${r.name}: ${p.msg}')
			}
		}
	}
}

fn print_counts(out Out, label string, m map[string]int) {
	if m.len == 0 {
		return
	}
	mut keys := m.keys()
	keys.sort_with_compare(fn [m] (a &string, b &string) int {
		if m[*a] != m[*b] {
			return m[*b] - m[*a]
		}
		return compare_strings(a, b)
	})
	mut total := 0
	for k in keys {
		total += m[k]
	}
	out.line('    ${label}: ${total}')
	for k in keys {
		out.line('      ${m[k]:7}  ${k}')
	}
}

// dump_rules writes one line per rule: schema, qualified name, element, wrapped, items with
// their types and resolved keys, the key as written, splittable, ordered, min, max, and the
// named types that hold the role.
fn dump_rules(mut sb strings.Builder, schema string, rs &arxmodel.RuleSet) {
	for r in rs.rules {
		items := r.items.map('${it.element}:${it.type_name}:${it.key.map(it.str()).join('|')}').join(' ')
		max := if r.max == arxmodel.unbounded { '*' } else { r.max.str() }
		mut held := r.held_by.map(rs.type_name(it)).filter(it != '')
		held.sort()
		sb.writeln('${schema}\t${r.name}\t${r.element}\t${r.wrapper}\t${items}\t${r.key_spec.join('|')}\t${r.splittable}\t${r.ordered}\t${r.min}\t${max}\t${held.join(' ')}')
	}
}

// Out is where the summary goes: standard output, or standard error when standard output
// carries the dump.
struct Out {
	err bool
}

fn (o Out) line(s string) {
	if o.err {
		eprintln(s)
	} else {
		println(s)
	}
}

fn ms(d time.Duration) string {
	return '${f64(d) / f64(time.millisecond):.1f} ms'
}

fn plural(n int, word string) string {
	return if n == 1 { '1 ${word}' } else { '${n} ${word}s' }
}

// load_policy is the policy named (spec, automat) or the file, or the built-in one.
fn load_policy(o Opts) arxmodel.Policy {
	return arxmodel.named_policy(o.policy) or {
		eprintln(err.msg())
		exit(2)
	}
}

// emit_rules writes the governing schema's merge rules to path.
fn emit_rules(out Out, sc &arxmodel.Schemas, path string) {
	flat, name := arxmodel.governing_flat(sc) or {
		eprintln('--emit: ${err.msg()}')
		exit(1)
	}
	u := sc.uses.filter(it.name == name)[0]
	text := arxmodel.format_rules(flat, arxmodel.provenance(u, sc.policy), sc.policy.settings()) or {
		eprintln('--emit: ${err.msg()}')
		exit(1)
	}
	os.write_file(path, text) or {
		eprintln('${path}: ${err.msg()}')
		exit(1)
	}
	out.line('wrote ${flat.rules.rules.len} rules of ${name} to ${path}')
}

// merged loads the files and merges them, by the schema or a rules file, running the layers
// the options leave in; it says what it read on out.
fn merged(o Opts, out Out, opts arxmodel.CheckOptions) (&arxmodel.Model, arxmodel.Schemas, arxmodel.Checked, time.Duration) {
	m := load_or_exit(o, out)
	policy := load_policy(o)
	ch := choose(o, [m], policy) or {
		if err is InputError {
			fail_input(o, m, err.msg())
		}
		eprintln(err.msg())
		exit(2)
	}
	sc := ch.sc
	print_undeclared(out, m, sc)
	if ch.typing == unsafe { nil } {
		line := rules_line(o, ch.name)
		out.line(if o.rules_file != '' {
			line + ' (arxmodel ${ch.pv.arxmodel}, flatxml ${ch.pv.flatxml})'
		} else {
			line
		})
		for w in ch.warnings {
			out.line('warning: ${w}')
		}
		if !(opts.skip_xml && opts.skip_multiplicity && opts.skip_references) {
			out.line('the XML schema and multiplicity layers need the schema: not checked; references are found by their DEST attribute and resolved by path, any kind fitting')
		}
	} else {
		out.line(rules_line(o, ch.name))
		for g in sc.governing {
			if g.use >= 0 {
				out.line('governed by ${sc.uses[g.use].name}${if g.note != '' {
					' (' + g.note + ')'
				} else {
					''
				}}')
			}
		}
	}
	sw := time.new_stopwatch()
	c := check_by(&ch, m, policy, opts) or { fail_input(o, m, err.msg()) }
	return m, sc, c, sw.elapsed()
}

// cmd_get prints the merged element at an AUTOSAR path: its element, and each file and line it
// is made of.
fn cmd_get(o Opts) {
	out := Out{}
	if o.paths.len < 2 {
		eprintln('get needs a path and the files')
		exit(2)
	}
	path := o.paths[0]
	mut rest := o
	rest.paths = o.paths[1..]
	_, _, c, _ := merged(rest, Out{
		err: true
	}, all_skipped())
	hs := c.index.holders(path)
	if hs.len == 0 {
		eprintln('nothing at ${path}')
		exit(1)
	}
	if hs.len > 1 {
		out.line('${path}: held by ${hs.len} elements, which the merge keeps apart')
	}
	mut v := c.view
	for k in hs {
		n := v.node(k)
		out.line('${c.index.path_of(k) or { '' }}: ${n.name()}, ${plural(n.fragment_count(), 'element')}, ${n.child_count()} below it')
		for f in n.fragments() {
			out.line('  ${v.pos(f)}')
		}
	}
}

// cmd_list prints the AUTOSAR path of every referrable element of one element name, a path held
// by two such elements once for each.
fn cmd_list(o Opts) {
	out := Out{}
	if o.paths.len < 2 {
		eprintln('list needs an element name and the files')
		exit(2)
	}
	kind := o.paths[0]
	mut rest := o
	rest.paths = o.paths[1..]
	_, _, c, _ := merged(rest, Out{
		err: true
	}, all_skipped())
	mut paths := []string{}
	for j, p in c.index.paths {
		if c.view.node(c.index.nodes[j]).name() == kind {
			paths << p
		}
	}
	paths.sort()
	for p in paths {
		out.line(p)
	}
	eprintln('${plural(paths.len, kind)}')
}

fn all_skipped() arxmodel.CheckOptions {
	return arxmodel.CheckOptions{
		skip_xml:          true
		skip_multiplicity: true
		skip_references:   true
	}
}

// check_options are the options given to check and merge, as the merge's.
fn check_options(o Opts) arxmodel.CheckOptions {
	return arxmodel.CheckOptions{
		jobs:              o.jobs
		skip_xml:          o.skip_xml
		skip_multiplicity: o.skip_mult
		skip_references:   o.skip_refs
		refs_from:         o.refs_from
		exclude:           o.exclude
		case_sensitive:    o.exact
		ignore_attrs:      o.ignore
		compare_attrs:     o.compare
	}
}

// fail_input ends a command whose input left nothing to check by (no schema governs the model):
// exit 1, check's report saying why where one is asked for.
@[noreturn]
fn fail_input(o Opts, m &arxmodel.Model, why string) {
	if o.format != 'text' {
		r := arxmodel.input_report(m, why)
		print(r.format(o.format))
		eprintln(why)
	} else {
		eprintln(why)
	}
	exit(1)
}

fn cmd_check(o Opts) {
	if o.format != 'text' {
		// the report alone on standard output, what was read on standard error
		m, sc, c, _ := merged(o, Out{ err: true }, check_options(o))
		r := arxmodel.check_report(m, sc, c)
		print(r.format(o.format))
		exit(if r.failed() { 1 } else { 0 })
	}
	out := Out{}
	m, sc, c, took := merged(o, out, check_options(o))
	errors := report(out, o, c, took)
	if m.failed.len > 0 || sc.undeclared.len > 0 || errors > 0 {
		exit(1)
	}
}

// cmd_merge merges and checks as check does, the summary on standard error, and writes the
// merged model as one document, unless there is a finding the policy calls an error, a file that
// could not be read or one that declares no schema (--force writes it anyway).
fn cmd_merge(o Opts) {
	out := Out{
		err: true
	}
	m, sc, c, took := merged(o, out, check_options(o))
	errors := report(out, o, c, took)
	if (m.failed.len > 0 || sc.undeclared.len > 0 || errors > 0) && !o.force {
		out.line('not written: ${plural(errors, 'error')}, ${plural(m.failed.len, 'file')} not read, ' +
			'${sc.undeclared.len} declaring no schema (--force writes it anyway)')
		exit(1)
	}
	sw := time.new_stopwatch()
	notes := arxmodel.export(c, m, sc, o.out) or {
		eprintln('${o.out}: ${err.msg()}')
		exit(1)
	}
	for n in notes {
		out.line('note: ${n}')
	}
	if o.out != '-' {
		out.line('wrote ${o.out} in ${ms(sw.elapsed())}: ${f64(os.file_size(o.out)) / 1e6:.1f} MB')
	}
}

// report prints what check found, and returns how many errors.
fn report(out Out, o Opts, c &arxmodel.Checked, took time.Duration) int {
	f := c.flat
	used := f.used()
	unused := f.unused()
	out.line('${f.rules.rules.len} flatxml rules; ${f.conflicts.len} element pairs in conflict (holders with different rules no parent path tells apart): ${used.len} used by the documents, ${unused.len} not')
	if o.problems {
		for x in unused {
			out.line('  unused conflict: ${x.parent} ${x.child}: ${x.rules.join('; ')}')
		}
	}
	out.line('${c.elements} elements merged into ${c.view.len()} nodes; ${c.merged} nodes made of more than one element, ${c.within} of them of two or more in one document')
	mut layers := []string{}
	for l in ['merge', 'paths', 'xml_schema', 'multiplicity', 'reference'] {
		if t := c.times[l] {
			layers << '${l} ${ms(t)}'
		}
	}
	out.line('checked in ${ms(took)}: ${layers.join(', ')}')
	out.line('${c.index.paths.len} referrable elements indexed by ${c.index.path_count()} AUTOSAR paths (${c.index.dup.len} held by more than one); ${c.refs.checked} references checked${if c.refs_from_files > 0 {
		', against ' + plural(c.refs_from_files, 'file') + ' loaded only to resolve them as well'
	} else {
		''
	}}')
	// the unresolved and external references by the top-level package they point into
	for kind in ['external', 'unresolved'] {
		mut tops := []string{}
		for k, _ in c.refs.by_top {
			if k.starts_with(kind + ' ') {
				tops << k
			}
		}
		if tops.len == 0 {
			continue
		}
		tops.sort_with_compare(fn [c] (a &string, b &string) int {
			return c.refs.by_top[*b] - c.refs.by_top[*a]
		})
		out.line('${kind} references by top-level package: ${tops.map('${it.all_after(' ')} ${c.refs.by_top[it]}').join(', ')}')
	}
	for w in c.input_warnings {
		out.line('warning: ${w}')
	}
	// what each filter of the policy matched
	for fl in arxmodel.filter_tallies(c) {
		why := if fl.reason != '' { ': ${fl.reason}' } else { '' }
		out.line('filter ${fl.number} (${fl.severity}${why}): ${plural(fl.matched, 'finding')}')
	}
	if c.unchecked_roles > 0 {
		out.line("${c.unchecked_roles} occurrences of roles whose wrapper holds its items' content with no element per item: their counts not checked")
	}
	if c.xml_fallback > 0 {
		out.line('${plural(c.xml_fallback, 'file')} checked against the governing XML schema, the one declared not being at hand')
	}
	errors, warnings, ignored := c.count(.error), c.count(.warning), c.count(.ignore)
	out.line('${errors} errors, ${warnings} warnings, ${ignored} ignored')
	// per severity, the count of each layer and kind, then the findings (the first 20 of a kind)
	for sev in [arxmodel.Severity.error, .warning, .ignore] {
		mut by := map[string]int{}
		for x in c.findings {
			if x.severity == sev {
				by['${x.layer}.${x.kind}${if x.in_conflict { ' (in conflict)' } else { '' }}']++
			}
		}
		if by.len == 0 {
			continue
		}
		out.line('${sev}s:')
		mut keys := by.keys()
		keys.sort()
		for k in keys {
			out.line('  ${by[k]:7}  ${k}')
		}
	}
	for sev in [arxmodel.Severity.error, .warning] {
		mut shown := map[string]int{}
		for x in c.findings {
			if x.severity != sev {
				continue
			}
			key := '${x.layer}.${x.kind}'
			if !o.all && shown[key] >= 20 {
				continue
			}
			shown[key]++
			out.line(x.str())
		}
	}
	return errors
}

// print_undeclared lists the files that declare no schema.
fn print_undeclared(out Out, m &arxmodel.Model, sc &arxmodel.Schemas) {
	if sc.undeclared.len == 0 {
		return
	}
	out.line('${plural(sc.undeclared.len, 'file')} with no schema declared:')
	mut ks := sc.undeclared.keys()
	ks.sort()
	for k in ks {
		out.line('  ${m.set.docs[k].path}: ${sc.undeclared[k]}')
	}
}
