module arxmodel

import os

fn tdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

fn release_named(name string) Release {
	return release_of(name) or { panic('no release in ${name}') }
}

fn test_release_order() {
	// dotted releases compare number by number; any numbered one is newer
	assert release_named('X_4-2-2.xsd').compare(release_named('X_4-3-0.xsd')) < 0
	assert release_named('X_4-10-0.xsd').compare(release_named('X_4-9-9.xsd')) > 0
	assert release_named('X_4-6-0.xsd').compare(release_named('X_00044.xsd')) < 0
	assert release_named('X_00046.xsd').compare(release_named('X_00049.xsd')) < 0
	assert release_named('x_4-0-3.XSD').compare(release_named('X_4-0-3.xsd')) == 0
	assert release_named('X_4-2.xsd').compare(release_named('X_4-2-0.xsd')) < 0
	assert release_named('LIB_1.xsd').str() == '1'
	assert release_of('plain.xsd') == none
	assert release_of('X_r4.xsd') == none
}

fn test_release_with_a_qualifier_and_a_family() {
	r := release_named('X_4-3-0_STRICT.xsd')
	assert r.str() == '4-3-0' && r.qualifier == 'strict' && r.prefix == 'x'
	assert r.compare(release_named('X_4-3-0.xsd')) == 0
	m := release_named('My_Lib_2_draft.xsd')
	assert m.prefix == 'my_lib' && m.str() == '2' && m.qualifier == 'draft'
}

// uses makes schema uses of one namespace: name, compiled or not, documents.
fn uses(spec []string) Schemas {
	mut sc := Schemas{}
	for x in spec {
		name, rest := x.split_once(' ') or { x, '' }
		sc.uses << &SchemaUse{
			name:  name
			ns:    'urn:x'
			docs:  []int{len: if rest.contains('docs') { 5 } else { 1 }}
			rules: if rest.contains('ok') { &RuleSet{} } else { unsafe { nil } }
			error: if rest.contains('ok') { '' } else { 'not found' }
		}
	}
	sc.choose_governing()
	return sc
}

fn use_names(sc Schemas, ks []int) []string {
	return ks.map(sc.uses[it].name)
}

fn test_governing_dotted_and_numbered() {
	sc := uses(['X_00046.xsd ok', 'X_4-6-0.xsd ok', 'X_4-2-2.xsd ok'])
	g := sc.governing[0]
	assert use_names(sc, g.ranked) == ['X_4-2-2.xsd', 'X_4-6-0.xsd', 'X_00046.xsd']
	assert sc.uses[g.use].name == 'X_00046.xsd' && g.note == ''
}

fn test_governing_falls_back_and_says_so() {
	sc := uses(['X_4-6-0.xsd ok', 'X_00053.xsd'])
	g := sc.governing[0]
	assert sc.uses[g.newest].name == 'X_00053.xsd'
	assert sc.uses[g.use].name == 'X_4-6-0.xsd'
	assert g.note.contains('X_00053.xsd') && g.note.contains('not found')
}

fn test_one_release_under_two_spellings() {
	// both compiled: no note
	a := uses(['X_4-0-3.xsd ok', 'x_4-0-3.xsd ok'])
	assert a.governing[0].note == '' && a.governing[0].use >= 0
	// the first not at hand, the second compiled: the second governs, with no note
	b := uses(['X_4-0-3.xsd', 'x_4-0-3.xsd ok'])
	assert b.uses[b.governing[0].use].name == 'x_4-0-3.xsd' && b.governing[0].note == ''
	// the first compiled, the second not at hand: the first governs, with no note
	c := uses(['X_4-0-3.xsd ok', 'x_4-0-3.xsd'])
	assert c.uses[c.governing[0].use].name == 'X_4-0-3.xsd' && c.governing[0].note == ''
}

fn test_families_rank_apart() {
	sc := uses(['A_5.xsd ok', 'B_9.xsd ok docs', 'B_8.xsd ok', 'plain.xsd ok'])
	g := sc.governing[0]
	assert g.family == 'b'
	assert use_names(sc, g.ranked) == ['B_8.xsd', 'B_9.xsd']
	assert use_names(sc, g.others) == ['A_5.xsd']
	assert use_names(sc, g.unranked) == ['plain.xsd']
	assert sc.uses[g.use].name == 'B_9.xsd'
}

fn test_newest_declared_governs_or_the_newest_at_hand() {
	mut m := load([tdata('releases')])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, tdata('schemas'), policy: automat_policy())
	assert sc.governing.len == 1
	g := sc.governing[0]
	assert sc.uses[g.newest].name == 'LIB_3.xsd'
	assert sc.uses[g.use].name == 'LIB_2.xsd'
	assert g.note.contains('LIB_3.xsd') && g.note.contains('not found')
	assert use_names(sc, g.ranked) == ['lib_1-9-9.xsd', 'LIB_1.xsd', 'LIB_2.xsd', 'LIB_3.xsd']
}

fn test_one_schema_file_governs_whatever_the_files_declare() {
	mut m := load([tdata('releases', 'newest.arxml')])!
	defer {
		m.free()
	}
	file := tdata('schemas', 'LIB_2', 'LIB_2.xsd')
	sc := compile_schemas(m, file, policy: automat_policy())
	assert sc.uses.len == 1 && sc.uses[0].docs == [0]
	assert sc.uses[sc.governing[0].use].name == 'LIB_2.xsd'
	assert sc.governing[0].note == ''
	// a schema of another namespace governs nothing
	other := compile_schemas(m, tdata('schemas', 'ALT_1', 'ALT_1.xsd'), policy: automat_policy())
	assert other.governing.len == 1 && other.governing[0].use < 0
	assert other.uses[0].error.contains('ALT_1.xsd is of namespace')
}

fn test_one_schema_file_governs_a_file_that_declares_none() {
	dir := os.join_path(os.vtmp_dir(), 'arxmodel_one_schema_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	f := os.join_path(dir, 'bare.arxml')
	os.write_file(f, '<LIBRARY xmlns="urn:arxmodel:test:lib"><SHELVES/></LIBRARY>')!
	mut m := load([f])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, tdata('schemas', 'LIB_2', 'LIB_2.xsd'), policy: automat_policy())
	assert sc.undeclared.len == 0 && sc.uses[0].docs == [0]
}

fn test_a_model_file_names_one_schema() {
	base := tdata('releases')
	mf := parse_model_file('paths = ["newest.arxml"]\nschema = "../schemas/LIB_2/LIB_2.xsd"\n',
		os.join_path(base, 'm.arxmodel.toml'))!
	assert mf.schema.ends_with('LIB_2.xsd')
	mut o := mf.open()!
	assert o.rules.contains('LIB_2.xsd')
	parse_model_file('paths = ["a"]\nschema = "a.xsd"\nschema_dir = "d"\n', 'x') or {
		assert err.msg().contains('merged by one')
		return
	}
	assert false
}

fn test_older_roles_and_documents_against_the_governing_schema() {
	mut m := load([tdata('releases')])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, tdata('schemas'), policy: automat_policy())
	g := sc.governing[0]
	gov := sc.uses[g.use]
	old := sc.uses.filter(it.name == 'LIB_1.xsd')[0]
	assert missing_roles(old.rules, gov.rules) == ['Shelf.broken (BROKEN-KEYS)']
	und := undeclared_elements(m, sc, g)
	assert und.len == 1
	assert und[0].name == 'BROKEN-KEYS' && und[0].count == 1 && und[0].files == 1
	assert und[0].first.contains('old.arxml')
}

fn test_one_schema_governs_alone() {
	mut m := load([tdata('model', 'a.arxml')])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, tdata('schemas'), policy: automat_policy())
	g := sc.governing[0]
	assert sc.uses[g.use].name == 'LIB_1.xsd' && g.note == ''
	assert undeclared_elements(m, sc, g).len == 0
}
