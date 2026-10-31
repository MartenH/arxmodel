module arxmodel

import os
import x.json2

fn ffdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

// filtered checks the reference fixture by the default policy with these filters added.
fn filtered(filters string) !Checked {
	p := parse_policy(default_policy_text + '\n' + filters)!
	m := load([ffdata('refs')])!
	return check(m, compile_schemas(m, ffdata('schemas'), policy: p), roots: [ffdata('refs')])
}

fn kinds_of(c Checked, severity Severity) []string {
	return c.findings.filter(it.severity == severity).map('${it.layer}.${it.kind}')
}

fn test_a_filter_needs_a_severity_and_known_fields() {
	for text, says in {
		'[[filter]]\nmatch = "reference.relative"':                                                     'filter 1: no `severity`'
		'[[filter]]\nmatch = "reference.relative"\nseverity = "maybe"':                                 '`severity` takes one of'
		'[[filter]]\nmatch = "reference.nope"\nseverity = "ignore"':                                    'filter 1: `match`: `reference.nope`: no kind `nope`'
		'[[filter]]\nwhere = "x"\nseverity = "ignore"':                                                 'filter 1: unknown field `where`'
		'[[filter]]\nseverity = "ignore"':                                                              'filter 1 matches every finding'
		'[[filter]]\nmessage_re = "(unclosed"\nseverity = "ignore"':                                    'filter 1: `message_re`'
		'[[filter]]\nmatch = "merge"\nseverity = "ignore"\n[[filter]]\nbase = ""\nseverity = "ignore"': 'filter 2: `base` takes a non-empty string'
	} {
		parse_policy(default_policy_text + '\n' + text) or {
			assert err.msg().contains(says), err.msg()
			continue
		}
		assert false, says
	}
}

fn test_match_and_base_and_dest() {
	before := filtered('')!
	assert kinds_of(before, .warning).filter(it == 'reference.relative').len == 2
	// the one with BASE="Library"
	c := filtered('[[filter]]\nmatch = "reference.relative"\nbase = "Library"\nseverity = "ignore"\nreason = "resolved elsewhere"')!
	rel := c.findings.filter(it.kind == 'relative')
	assert rel.map(it.severity) == [Severity.ignore, .warning]
	assert rel[0].filter == 1 && rel[0].reason == 'resolved elsewhere' && rel[0].was == .warning
	assert c.filter_counts == [1]
	// DEST
	d := filtered('[[filter]]\nmatch = "reference.wrong_kind"\ndest = "VARIABLE"\nseverity = "warning"')!
	assert d.findings.filter(it.kind == 'wrong_kind' && it.severity == .warning).map(it.dest) == ['VARIABLE']
}

fn test_message_path_and_file() {
	// a substring, and a whole-message XML Schema pattern
	m := filtered('[[filter]]\nmessage = "/Elsewhere/"\nseverity = "ignore"\n[[filter]]\nmessage_re = "nothing at `/Fiction/Missing`.*"\nseverity = "warning"')!
	assert m.findings.filter(it.filter == 1).map(it.kind) == ['external']
	assert m.findings.filter(it.filter == 2).map(it.kind) == ['unresolved']
	// a path: `*` one segment, `**` any, `#` a segment
	p := filtered('[[filter]]\npath = "/*#PICK-REF"\nmatch = "reference.empty"\nseverity = "warning"')!
	assert p.findings.filter(it.kind == 'empty').map(it.severity) == [Severity.warning]
	assert path_glob('/Fiction#PICK-REF', '/Fiction#PICK-REF') && path_glob('/*#*', '/Fiction#PICK-REF')
	assert !path_glob('/*', '/Fiction/Dune') && path_glob('/**', '/Fiction/Dune')
	assert path_glob('/**/Dune', '/Fiction/Dune') && path_glob('/Fic*/D?ne', '/Fiction/Dune')
	assert path_glob('/AUTOSAR/**#DESC', '/AUTOSAR/EcucDefs/Dem/X#DESC')
	assert !path_glob('/AUTOSAR/**#DESC', '/AUTOSAR/EcucDefs/Dem/X#DESC/L-2')
	assert path_glob('**#DESC/**', '/A/B#DESC/L-2')
	// a key's `/` and `#` divide nothing; a keyed element matched by its name or its key
	assert segments('/A#P/V[,/D/x,]/X[#2]') == ['A', '#', 'P', 'V[,/D/x,]', 'X[#2]']
	assert path_glob('/A#P/V/X', '/A#P/V[,/D/x,]/X[#2]') && path_glob('/A#P/V[,/D/x,]/*', '/A#P/V[,/D/x,]/X[#2]')
	assert !path_glob('/A#P/V[,/D/y,]/*', '/A#P/V[,/D/x,]/X[#2]')
	// a file: relative to the paths checked, or absolute
	f := filtered('[[filter]]\nfile = "r.arxml"\nmatch = "reference.duplicate_path"\nseverity = "warning"')!
	assert f.findings.filter(it.kind == 'duplicate_path').all(it.severity == .warning)
	assert file_glob('*.arxml', ffdata('refs', 'r.arxml'), [ffdata('refs')])
	assert file_glob('**/r.arxml', ffdata('refs', 'r.arxml'), [ffdata()])
	assert !file_glob('*.arxml', ffdata('refs', 'r.arxml'), [ffdata()])
	assert file_glob(ffdata('**', 'r.arxml'), ffdata('refs', 'r.arxml'), [])
}

fn test_the_first_filter_that_matches_wins() {
	c := filtered('[[filter]]\nmatch = "reference.relative"\nseverity = "ignore"\nreason = "first"\n[[filter]]\nmatch = "reference"\nseverity = "warning"\nreason = "second"')!
	assert c.findings.filter(it.kind == 'relative').all(it.filter == 1 && it.severity == .ignore)
	assert c.findings.filter(it.layer == .reference && it.kind != 'relative').all(it.filter == 2
		&& it.severity == .warning)
	assert c.filter_counts[0] == 2 && c.filter_counts[1] > 0
}

fn test_an_unused_filter_is_reported() {
	c := filtered('[[filter]]\nmatch = "merge.collision"\nseverity = "ignore"\nreason = "old"')!
	u := c.findings.filter(it.layer == .policy)
	assert u.len == 1 && u[0].kind == 'unused_filter' && u[0].severity == .warning
	assert u[0].message == 'filter 1 (old) matched no finding'
	assert c.filter_counts == [0]
}

fn test_the_reports_carry_the_filters() {
	m := load([ffdata('refs')])!
	p := parse_policy(default_policy_text + '\n[[filter]]\nmatch = "reference.relative"\nseverity = "ignore"\nreason = "traced"')!
	sc := compile_schemas(m, ffdata('schemas'), policy: p)
	c := check(m, sc, roots: [ffdata('refs')])!
	r := check_report(m, sc, &c)
	doc := json2.decode[json2.Any](r.json(all: true))!.as_map()
	filters := doc['summary']!.as_map()['filters']!.as_array()
	assert filters.len == 1 && filters[0].as_map()['matched']!.int() == 2
		&& filters[0].as_map()['reason']!.str() == 'traced'
	mut marked := 0
	for f in doc['findings']!.as_array() {
		if x := f.as_map()['filter'] {
			assert x.int() == 1 && f.as_map()['policy_severity']!.str() == 'warning'
			marked++
		}
	}
	assert marked == 2
	j := r.junit()
	assert j.contains('<property name="filter 1" value="2 matched, ignore: traced"/>')
	assert !j.contains('relative to a base')
}

fn test_a_policy_with_filters_is_shown_and_compared() {
	p := parse_policy(default_policy_text + '\n[[filter]]\nmatch = "reference.relative"\nbase = "Trace"\nseverity = "ignore"\nreason = "traced"')!
	assert p.filters[0].toml() == '{ match = "reference.relative", base = "Trace", severity = "ignore", reason = "traced" }'
	assert policy_diff(default_policy(), p) == ['[[filter]] 1: (none) -> { match = "reference.relative", base = "Trace", severity = "ignore", reason = "traced" }']
}

fn test_in_conflict_is_matched_as_severity_matches_it() {
	p := parse_policy(default_policy_text + '\n[[filter]]\nmatch = "merge.in_conflict"\nseverity = "ignore"')!
	f := p.filters[0]
	assert f.matches(&Finding{ layer: .merge, kind: 'collision', in_conflict: true }, [])
	assert !f.matches(&Finding{ layer: .merge, kind: 'collision' }, [])
}

fn test_a_filter_may_match_another_filter_s_report() {
	// filter 2 ignores filter 1's report: 2 is used, 1's report is ignored
	c := filtered('[[filter]]\nmatch = "merge.collision"\nseverity = "ignore"\n[[filter]]\nmatch = "policy.unused_filter"\nseverity = "ignore"\nreason = "known"')!
	u := c.findings.filter(it.layer == .policy)
	assert u.map('${it.what} ${it.severity} ${it.filter}') == ['filter 1 ignore 2']
	assert c.filter_counts == [0, 1]
	// a filter does not use itself up on its own report
	d := filtered('[[filter]]\nmatch = "policy.unused_filter"\nseverity = "ignore"')!
	assert d.findings.filter(it.layer == .policy).map('${it.what} ${it.severity}') == ['filter 1 warning']
}

fn test_a_filter_of_a_layer_that_did_not_run_is_not_unused() {
	p := parse_policy(default_policy_text + '\n[[filter]]\nmatch = "xml_schema.invalid_value"\nseverity = "ignore"')!
	m := load([ffdata('refs')])!
	sc := compile_schemas(m, ffdata('schemas'), policy: p)
	ran := check(m, sc, roots: [ffdata('refs')])!
	skipped := check(m, sc, roots: [ffdata('refs')], skip_xml: true)!
	assert ran.filter_counts == [1]
	assert skipped.filter_counts == [0] && !skipped.findings.any(it.layer == .policy)
}

fn test_the_policy_s_own_findings_are_warnings_where_it_says_nothing() {
	text := default_policy_text.replace('"policy.unused_filter" = "warning"\n', '')
	assert !text.contains('policy.unused_filter" =')
	p := parse_policy(text + '\n[[filter]]\nmatch = "merge.collision"\nseverity = "ignore"')!
	assert p.severity(.policy, 'unused_filter', '') == .warning
	assert p.severity(.merge, 'nothing_said', '') == .error
}

fn test_keys_with_brackets_keep_their_segments() {
	assert escape_key('a[b]\\c') == 'a\\[b\\]\\\\c'
	path := '/A#B[${escape_key('x[y')}]/C'
	assert segments(path) == ['A', '#', 'B[x\\[y]', 'C']
	assert path_glob('/A#B/C', path) && path_glob('/A#B[x\\[y]/*', path)
	assert !path_glob('/A#B[x]/*', path)
}

fn test_star_does_not_match_the_inner_part_s_mark() {
	assert !path_glob('/*/*', '/A#X') && !path_glob('/*/?', '/A#X')
	assert path_glob('/*#*', '/A#X') && path_glob('/**', '/A#X')
}

fn test_a_result_check_applies_no_file_filter_and_reports_none_unused() {
	p := parse_policy(default_policy_text + '\n[[filter]]\nfile = "r.arxml"\nseverity = "ignore"\n[[filter]]\nmatch = "merge.collision"\nseverity = "ignore"')!
	x := Finding{
		layer:    .reference
		kind:     'empty'
		severity: .error
		at:       ['r.arxml:1:1']
	}
	out, counts := apply_filters([x], p, FilterOptions{
		result: true
	})
	assert out.len == 1 && out[0].severity == .error && counts == [0, 0]
	plain, _ := apply_filters([x], p, FilterOptions{})
	assert plain[0].severity == .ignore && plain.filter(it.layer == .policy).len == 1
}

fn test_relative_file_filters_read_from_the_input_set_s_bases() {
	// the model read through a list: a relative file glob is read from where its files came from
	dir := os.join_path(os.temp_dir(), 'arxmodel_fbases_${os.getpid()}')
	os.mkdir_all(dir)!
	list := os.join_path(dir, 'args.txt')
	os.write_file(list, ffdata('refs') + '\n')!
	p := parse_policy(default_policy_text + '\n[[filter]]\nfile = "r.arxml"\nmatch = "reference.empty"\nseverity = "ignore"')!
	m := load(['@' + list])!
	c := check(m, compile_schemas(m, ffdata('schemas'), policy: p))!
	assert c.filter_counts == [1]
}

fn test_refs_from_takes_the_input_set_rules() {
	p := default_policy()
	m := load([ffdata('refs')])!
	c := check(m, compile_schemas(m, ffdata('schemas'), policy: p),
		refs_from: [ffdata('refs_extra'), ffdata('refs_extra', '*.nothing')]
		exclude:   ['**/e.arxml']
	)!
	assert c.refs_from_files == 0
	assert c.input_warnings.len == 1 && c.input_warnings[0].ends_with('*.nothing: matches nothing')
}
