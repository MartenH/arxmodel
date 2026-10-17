module arxmodel

import os

const identity_line = 'item_identity = { "EcucContainerValue.parameterValue" = "definition", "EcucContainerValue.referenceValue" = "definition" }'

// a policy identifying the synthetic schema's settings by their definition, or nothing so
fn vk_policy(identity string) Policy {
	assert automat_policy_text.contains(identity_line)
	return parse_policy(automat_policy_text.replace(identity_line, 'item_identity = ${identity}')) or {
		panic(err)
	}
}

// vk_model writes documents, each a shelf holding the settings given, and loads them.
fn vk_model(name string, settings ...string) &Model {
	dir := os.join_path(os.temp_dir(), 'arxmodel_vk_${os.getpid()}', name)
	os.mkdir_all(dir) or { panic(err) }
	for k, s in settings {
		os.write_file(os.join_path(dir, '${k}.arxml'), '<?xml version="1.0" encoding="UTF-8"?>
<LIBRARY xmlns="urn:arxmodel:test:lib" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:arxmodel:test:lib LIB_1.xsd">
<SHELVES><SHELF><SHORT-NAME>Fiction</SHORT-NAME><SETTINGS>${s}</SETTINGS></SHELF></SHELVES>
</LIBRARY>') or {
			panic(err)
		}
	}
	return load([dir]) or { panic(err) }
}

fn setting(def string, value string) string {
	return '<SETTING><DEFINITION-REF>${def}</DEFINITION-REF><VALUE>${value}</VALUE></SETTING>'
}

fn vk_schemas(m &Model, p Policy) Schemas {
	return compile_schemas(m, os.join_path(@VMODROOT, 'testdata', 'schemas'), policy: p)
}

fn settings_of(c Checked) int {
	mut n := 0
	for i in 0 .. c.view.len() {
		if c.view.node(u32(i)).name() == 'SETTING' {
			n++
		}
	}
	return n
}

fn test_a_value_is_identified_by_its_definition() {
	// two files giving one definition different values: one value that differs
	m := vk_model('split', setting('/d/x', '1'), setting('/d/x', '2'))
	by_def := vk_policy('{ "Shelf.setting" = "definition" }')
	c := check(m, vk_schemas(m, by_def), skip_xml: true, skip_references: true)!
	assert settings_of(c) == 1
	assert c.findings.any(it.kind == 'value_differs' && it.what == 'VALUE')
	// keyed by every single-valued child, the value included: two values, nothing said
	all := vk_policy('{}')
	d := check(m, vk_schemas(m, all), skip_xml: true, skip_references: true)!
	assert settings_of(d) == 2
	assert !d.findings.any(it.layer == .merge)
}

fn test_a_definition_given_twice_is_a_set() {
	m := vk_model('multi', setting('/d/m', '1') + setting('/d/m', '2') + setting('/d/x', '7'))
	p := vk_policy('{ "Shelf.setting" = "definition" }')
	c := check(m, vk_schemas(m, p), skip_xml: true, skip_references: true)!
	assert settings_of(c) == 3
	assert !c.findings.any(it.layer == .merge)
}

fn test_merge3_by_definition() {
	p := vk_policy('{ "Shelf.setting" = "definition" }')
	base := vk_model('base', setting('/d/x', '1') + setting('/d/m', '1'))
	// one value both sides change: a conflict
	ours := vk_model('ours', setting('/d/x', '2') + setting('/d/m', '1'))
	theirs := vk_model('theirs', setting('/d/x', '3') + setting('/d/m', '1'))
	// a value of a definition given several values, added on each side: both kept
	more_o := vk_model('more_o', setting('/d/x', '1') + setting('/d/m', '1') + setting('/d/m', '2'))
	more_t := vk_model('more_t', setting('/d/x', '1') + setting('/d/m', '1') + setting('/d/m', '3'))
	dir := os.join_path(@VMODROOT, 'testdata', 'schemas')
	r := ruling_by_schema([base, ours, theirs], dir, p, CheckOptions{})!
	b, o, t := r.read(base)!, r.read(ours)!, r.read(theirs)!
	clash := r.merge3(&b, &o, &t)!
	assert clash.conflicts.map(it.line().all_before('  ')) == ['! /Fiction#SETTINGS/SETTING[/d/x,]/VALUE: text "2" / "3"']
	s := ruling_by_schema([base, more_o, more_t], dir, p, CheckOptions{})!
	b2, o2, t2 := s.read(base)!, s.read(more_o)!, s.read(more_t)!
	mut both := s.merge3(&b2, &o2, &t2)!
	assert both.conflicts.len == 0
	text := both.m3.edit.doc_edit(0).xml()
	assert text.count('<SETTING>') == 4 && text.contains(setting('/d/m', '2'))
		&& text.contains(setting('/d/m', '3'))
}

fn test_a_rules_file_keeps_the_identity_roles() {
	p := vk_policy('{ "Shelf.setting" = "definition" }')
	m := vk_model('rules', setting('/d/x', '1'))
	sc := vk_schemas(m, p)
	flat, name := governing_flat(sc)!
	assert flat.identity_roles.map('${it.parent} ${it.items} ${it.definition} ${it.label}') == [
		"SETTINGS ['SETTING'] DEFINITION-REF VARIATION-POINT/SHORT-LABEL",
	]
	u := sc.uses.filter(it.name == name)[0]
	text := format_rules(flat, provenance(u, p), p.settings())!
	back, _, _ := parse_rules_file(text)!
	assert back.identity_roles == flat.identity_roles
}

fn test_values_by_the_schemas_identity_roles() {
	p := vk_policy('{ "Shelf.setting" = "definition" }')
	// the label after the value (SETTING writes VARIATION-POINT last): the value stays the value
	labelled := '<SETTING><DEFINITION-REF>/d/x</DEFINITION-REF><VALUE>1</VALUE><VARIATION-POINT><SHORT-LABEL>v1</SHORT-LABEL></VARIATION-POINT></SETTING>'
	m := vk_model('labelled', labelled)
	c := check(m, vk_schemas(m, p), skip_xml: true, skip_references: true)!
	vals := c.values('/Fiction/**').map(it.line())
	assert vals == ['/Fiction/x[v1] = "1"', '/Fiction/x[v1]#VARIATION-POINT/SHORT-LABEL = "v1"'], vals.str()
	// each_value gives what values gives, one at a time
	mut seen := &[]string{}
	n := c.each_value('/Fiction/**', fn [mut seen] (v Value) {
		seen << v.line()
	})
	assert n == 2 && *seen == vals
}

fn test_values_of_a_role_with_no_wrapper() {
	// the policy identifies a role written in its holder, with no wrapper, by its definition
	dir := os.join_path(os.temp_dir(), 'arxmodel_vk_${os.getpid()}', 'direct')
	os.mkdir_all(dir)!
	os.write_file(os.join_path(dir, 'a.arxml'), '<?xml version="1.0" encoding="UTF-8"?>
<DEPOT xmlns="urn:arxmodel:test:direct" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:arxmodel:test:direct DIRECT_1.xsd">
<STORES><STORE><SHORT-NAME>Main</SHORT-NAME><OPTION><DEFINITION-REF>/d/x</DEFINITION-REF><VALUE>1</VALUE></OPTION><OPTION><DEFINITION-REF>/d/y</DEFINITION-REF><VALUE>2</VALUE></OPTION></STORE></STORES>
</DEPOT>')!
	m := load([dir])!
	p := vk_policy('{ "Store.option" = "definition" }')
	c := check(m, vk_schemas(m, p), skip_xml: true, skip_references: true)!
	assert c.values('/Main/**').map(it.line()) == ['/Main/x = "1"', '/Main/y = "2"']
	// through a rules file, the same: the file records the role
	sc := vk_schemas(m, p)
	flat, _ := governing_flat(sc)!
	text := format_rules(flat, provenance(governing_use(sc)!, p), p.settings())!
	assert text.contains('\n# direct-identity: OPTION DEFINITION-REF')
	g, _, st := parse_rules_file(text)!
	assert g.direct_identities.len == 1
	d := check_with(m, g, 'rules file', st, p, skip_xml: true, skip_references: true)!
	assert d.values('/Main/**').map(it.line()) == ['/Main/x = "1"', '/Main/y = "2"']
}

fn test_values_of_a_role_keyed_by_another_part_first() {
	// the split key gives a kind before the item itself: the identity is the definition still
	dir := os.join_path(os.temp_dir(), 'arxmodel_vk_${os.getpid()}', 'direct_kind')
	os.mkdir_all(dir)!
	os.write_file(os.join_path(dir, 'a.arxml'), '<?xml version="1.0" encoding="UTF-8"?>
<DEPOT xmlns="urn:arxmodel:test:direct" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:arxmodel:test:direct DIRECT_1.xsd">
<STORES><STORE><SHORT-NAME>Main</SHORT-NAME><CHOICE><KIND>k</KIND><DEFINITION-REF>/d/z</DEFINITION-REF><VALUE>3</VALUE></CHOICE></STORE></STORES>
</DEPOT>')!
	m := load([dir])!
	p := vk_policy('{ "Store.choice" = "definition" }')
	c := check(m, vk_schemas(m, p), skip_xml: true, skip_references: true)!
	vals := c.values('/Main/**').map(it.line())
	assert '/Main/z = "3"' in vals, vals.str()
	assert !vals.any(it.starts_with('/Main/k')), vals.str()
}
