// arxmodel — command-line access to AUTOSAR models.
//
//   arxmodel load [--jobs N] <file|dir>...    read every .arxml into one set, print what it holds
//   arxmodel rules --schema-dir DIR [--jobs N] [--problems] [--dump FILE] <file|dir>...
//                                              read them, find and compile the schemas they
//                                              declare, and print the merge rules each gives
//   arxmodel check --schema-dir DIR [--all] [--case-sensitive] [--ignore-attr NAME]... [--check-attr NAME]... <file|dir>...
//                                              merge the files by the rules of the governing
//                                              schema and list what the rules forbid
//
// Each exits 1 when a file could not be read, or (rules) a schema was not declared, not found
// or did not compile; what could be done is still printed.
module main

import arxmodel
import os
import strings
import time

const usage = 'usage:
  arxmodel load [--jobs N] <file|dir>...
      read every .arxml below the paths into one document set and print what it holds
  arxmodel rules --schema-dir DIR [--jobs N] [--problems] [--dump FILE] <file|dir>...
      also find each declared schema in DIR, compile each once, and print its merge rules;
      --problems lists every annotation that could not be applied, --dump writes the rules
      as tab-separated lines (FILE, or - for standard output, the summary then going to
      standard error)
  arxmodel check --schema-dir DIR [--all] [--case-sensitive] [--ignore-attr NAME]... <file|dir>...
      merge the files into one model by the rules of the newest declared release (or the newest
      at hand), and list what the rules forbid with every file and line: the first 20 of each
      kind, or --all; keys ignore ASCII case unless --case-sensitive; --ignore-attr names an
      attribute whose values may differ between fragments (namespace declarations, xsi
      attributes and UUID may; --check-attr UUID compares it after all)'

struct Opts {
mut:
	jobs       int
	schema_dir string
	problems   bool
	dump       string
	all        bool     // check: every problem, not the first of each kind
	exact      bool     // check: keys compared as written
	ignore     []string // check: attributes whose values may differ between fragments
	compare    []string // check: attributes ignored by default that are compared after all
	paths      []string
}

fn main() {
	args := os.args[1..]
	if args.len < 1 {
		eprintln(usage)
		exit(2)
	}
	opts := parse_opts(args[1..]) or {
		eprintln(err.msg())
		eprintln(usage)
		exit(2)
	}
	match args[0] {
		'load' {
			cmd_load(opts)
		}
		'check' {
			if opts.schema_dir == '' {
				eprintln('check needs --schema-dir')
				exit(2)
			}
			cmd_check(opts)
		}
		'rules' {
			if opts.schema_dir == '' {
				eprintln('rules needs --schema-dir')
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
		match a {
			'--ignore-attr', '--check-attr' {
				if k + 1 >= args.len {
					return error('${a} needs a value')
				}
				if a == '--ignore-attr' {
					o.ignore << args[k + 1]
				} else {
					o.compare << args[k + 1]
				}
				k += 2
				continue
			}
			'--all' {
				o.all = true
			}
			'--case-sensitive' {
				o.exact = true
			}
			'--jobs', '--schema-dir', '--dump' {
				if k + 1 >= args.len {
					return error('${a} needs a value')
				}
				v := args[k + 1]
				match a {
					'--jobs' { o.jobs = v.int() }
					'--schema-dir' { o.schema_dir = v }
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
	if o.paths.len == 0 {
		return error('no files or directories given')
	}
	return o
}

fn load_or_exit(o Opts, out Out) &arxmodel.Model {
	m := arxmodel.load(o.paths, jobs: o.jobs) or {
		eprintln(err.msg())
		exit(1)
	}
	mb := f64(m.bytes) / 1e6
	out.line('${m.files.len} files, ${m.set.docs.len} loaded (${mb:.1f} MB) in ${ms(m.took)}, ${m.failed.len} failed')
	for f in m.failed {
		out.line('  failed: ${f.msg}')
	}
	return m
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
	sw := time.new_stopwatch()
	sc := arxmodel.compile_schemas(m, o.schema_dir)
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

// default_ignored are the attributes check lets differ between fragments unless asked to compare
// them (--check-attr): a UUID is often generated per file for one element.
const default_ignored = ['UUID']

fn cmd_check(o Opts) {
	out := Out{}
	m := load_or_exit(o, out)
	sc := arxmodel.compile_schemas(m, o.schema_dir)
	print_undeclared(out, m, sc)
	for g in sc.governing {
		if g.use >= 0 {
			out.line('governed by ${sc.uses[g.use].name}${if g.note != '' {
				' (' + g.note + ')'
			} else {
				''
			}}')
		}
	}
	sw := time.new_stopwatch()
	mut ignore := o.ignore.clone()
	for a in default_ignored {
		if a !in o.compare {
			ignore << a
		}
	}
	mut c := arxmodel.check(m, sc, case_sensitive: o.exact, ignore_attrs: ignore) or {
		out.line(err.msg())
		exit(1)
	}
	took := sw.elapsed()
	f := c.flat
	out.line('${f.rules.rules.len} flatxml rules; ${c.pairs.len} element pairs that roles of different holders give different rules: ${f.settled.len} settled by the holders the documents use, ${f.conflicts.len} in conflict where the documents use them, ${f.unused.len} in conflict and unused')
	out.line('  ${f.key_fns} keyed rules (absent parts read as empty), ${f.lost_keys} item kinds one child each for a key part that did not resolve, ${f.flat_wrappers} wrappers of item content whose items are not told apart')
	for x in f.conflicts {
		out.line('  conflict: ${x.parent} ${x.child} (${x.occurs} in the documents): ${x.rules.join('; ')}')
	}
	if o.problems {
		for x in f.unused {
			out.line('  unused conflict: ${x.parent} ${x.child}: ${x.rules.join('; ')}')
		}
		for x in f.settled {
			out.line('  settled: ${x.parent} ${x.child}: ${x.rules.join('; ')}')
		}
	}
	mut v := c.view
	out.line('${c.elements} elements merged into ${v.len()} nodes in ${ms(took)}; ${c.merged} nodes made of more than one element, ${c.within} of them of two or more in one document')
	mut by_kind := map[string]int{}
	mut by_kind_conflict := map[string]int{}
	for k, p in v.problems {
		if c.in_conflict[k] {
			by_kind_conflict['${p.kind}']++
		} else {
			by_kind['${p.kind}']++
		}
	}
	out.line('${c.violations} problems, and ${v.problems.len - c.violations} on element pairs in conflict (judged by a rule that may not be theirs)')
	mut kinds := by_kind.keys()
	kinds.sort()
	for k in kinds {
		out.line('  ${by_kind[k]:7}  ${k}')
	}
	mut ckinds := by_kind_conflict.keys()
	ckinds.sort()
	for k in ckinds {
		out.line('  ${by_kind_conflict[k]:7}  ${k} (in conflict)')
	}
	mut shown := map[string]int{}
	for k, p in v.problems {
		key := '${p.kind}${c.in_conflict[k]}'
		if !o.all && shown[key] >= 20 {
			continue
		}
		shown[key]++
		out.line((if c.in_conflict[k] { 'in conflict: ' } else { '' }) + v.describe(p))
	}
	if m.failed.len > 0 || sc.undeclared.len > 0 || c.violations > 0 || f.conflicts.len > 0 {
		exit(1)
	}
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
