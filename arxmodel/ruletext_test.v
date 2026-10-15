module arxmodel

import flatxml
import os

fn rdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

// emit makes a rules file from the documents at path, by the policy p.
fn emit(path string, schemas string, p Policy) string {
	m := load([rdata(path)]) or { panic(err) }
	sc := compile_schemas(m, rdata(schemas), policy: p)
	f, name := governing_flat(sc) or { panic(err) }
	u := sc.uses.filter(it.name == name)[0]
	return format_rules(f, provenance(u, p), p.settings()) or { panic(err) }
}

fn problems_of(mut c Checked) []string {
	mut v := c.view
	return v.problems.map(v.describe(it))
}

fn test_rules_text_reads_back_to_the_same_rules() {
	m := load([rdata('model', 'a.arxml')])!
	sc := compile_schemas(m, rdata('schemas'))
	f, _ := governing_flat(sc)!
	text := emit('model/a.arxml', 'schemas', default_policy())
	// flatxml reads it; the item's own text is `.` there, arxmodel's reader makes it '' again
	raw := flatxml.parse_rules(text)!
	assert raw.rules.len == f.rules.rules.len
	g, pv, st := parse_rules_file(text)!
	for k, r in f.rules.rules {
		x := g.rules.rules[k]
		// flatxml reads the own text back as `.`, which compiles as '' does
		assert x.parent == r.parent && x.children == r.children
		assert x.key.map(if it == '.' { '' } else { it }) == r.key
		assert x.keyless == r.keyless && x.single == r.single && x.merge == r.merge
		assert x.ordered == r.ordered && x.max == r.max
	}
	assert pv.schema == 'LIB_1.xsd' && pv.namespace == 'urn:arxmodel:test:lib'
	assert pv.schema_sha256.len == 64 && pv.arxmodel == version && pv.flatxml == flatxml_commit
	assert pv.policy == default_policy().rule_settings()
	// the settings are the policy's, with no document's attributes in them
	assert st.fold && st.ignore_attrs == ['UUID'] && st.ignore_declarations
	assert !text.contains('xsi:schemaLocation')
	assert text.contains('BOOK/NOTES NOTE key=. keyless=empty merge')
}

fn test_a_file_made_from_some_documents_merges_others_like_the_schema() {
	// made from model/a.arxml, applied to merge/x and merge/y
	text := emit('model/a.arxml', 'schemas', default_policy())
	mut m := load([rdata('merge')])!
	defer {
		m.free()
	}
	g, pv, st := parse_rules_file(text)!
	sc := compile_schemas(m, rdata('schemas'))
	mut by_schema := check(m, sc)!
	mut by_file := check_with(m, g, pv.schema, st, default_policy(), CheckOptions{})!
	assert by_schema.view.len() == by_file.view.len()
	assert problems_of(mut by_schema) == problems_of(mut by_file)
	assert by_schema.violations == by_file.violations
}

fn test_conflicts_are_kept_and_placed_against_the_documents_checked() {
	// made from documents that do not use the pair in conflict
	text := emit('roots/plain.arxml', 'schemas', default_policy())
	g, pv, st := parse_rules_file(text)!
	assert g.conflicts.len == 1 && g.conflicts[0].parent == '/ROOT' && g.conflicts[0].rules.len == 2
	// applied to documents that do
	mut m := load([rdata('roots', 'items.arxml')])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, rdata('schemas'))
	by_schema := check(m, sc)!
	by_file := check_with(m, g, pv.schema, st, default_policy(), CheckOptions{})!
	assert by_schema.flat.used().len == 1 && by_file.flat.used().len == 1
	assert by_file.flat.used()[0].occurs == by_schema.flat.used()[0].occurs
	// and to the documents it was made from, which do not
	mut m2 := load([rdata('roots', 'plain.arxml')])!
	defer {
		m2.free()
	}
	plain := check_with(m2, g, pv.schema, st, default_policy(), CheckOptions{})!
	assert plain.flat.used().len == 0 && plain.flat.unused().len == 1
}

fn test_a_file_for_other_documents_is_refused() {
	text := emit('model/a.arxml', 'schemas', default_policy())
	_, pv, st := parse_rules_file(text)!
	// another namespace
	mut m := load([rdata('roots', 'items.arxml')])!
	defer {
		m.free()
	}
	if _ := rules_file_check(declare_schemas(m), pv, st, default_policy()) {
		assert false
	}
	// another family in the one namespace
	other := Provenance{
		...pv
		schema: 'OTHER_9.xsd'
	}
	mut m2 := load([rdata('model', 'a.arxml')])!
	defer {
		m2.free()
	}
	if _ := rules_file_check(declare_schemas(m2), other, st, default_policy()) {
		assert false
	}
	// the documents it governs
	ok := rules_file_check(declare_schemas(m2), pv, st, default_policy())!
	assert ok.len == 0
}

fn test_newer_releases_and_another_policy_are_said() {
	text := emit('model/a.arxml', 'schemas', default_policy())
	_, pv, st := parse_rules_file(text)!
	mut m := load([rdata('releases')])!
	defer {
		m.free()
	}
	ws := rules_file_check(declare_schemas(m), pv, st, default_policy())!
	assert ws.len == 2
	assert ws.any(it.starts_with('LIB_2.xsd')) && ws.any(it.starts_with('LIB_3.xsd'))
	// every setting that differs is named, whichever kind
	newest := Provenance{
		...pv
		schema: 'LIB_3.xsd'
	}
	mut p := parse_policy(default_policy_text.replace('absent_keys empty', 'absent_keys own').replace('key_case ignore',
		'key_case exact'))!
	diff := rules_file_check(declare_schemas(m), newest, st, p)!
	assert diff.len == 2
	assert diff.any(it.contains('absent_keys')) && diff.any(it.contains('key_case'))
	// comments and line endings are not settings
	p = parse_policy(default_policy_text.replace('\n', '\r\n') + '# another comment\n')!
	assert rules_file_check(declare_schemas(m), newest, st, p)!.len == 0
}

fn test_not_a_rules_file() {
	if _, _, _ := parse_rules_file('SHELF SHORT-NAME single merge\n') {
		assert false
	}
}

fn test_flatxml_alone_merges_by_the_file_as_arxmodel_does() {
	text := emit('model/a.arxml', 'schemas', default_policy())
	mut m := load([rdata('merge')])!
	defer {
		m.free()
	}
	// flatxml's own reader and merge, nothing of arxmodel's
	rs := flatxml.parse_rules(text)!
	mut plain := m.set.merge(rs)!
	g, pv, st := parse_rules_file(text)!
	mut ours := check_with(m, g, pv.schema, st, default_policy(), CheckOptions{})!
	assert plain.len() == ours.view.len()
	assert plain.problems.map(plain.describe(it)) == ours.view.problems.map(ours.view.describe(it))
}
