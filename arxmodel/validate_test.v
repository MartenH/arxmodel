module arxmodel

import flatxml.xsd
import os

fn vdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

// vpolicy is the built-in policy with keys added to its [severity] table.
fn vpolicy(extra string) Policy {
	return parse_policy(default_policy_text.replace('\n[severity]\n', '\n[severity]\n${extra}\n')) or {
		panic(err)
	}
}

fn test_severity_by_layer_kind_and_what() {
	p := vpolicy('"merge.value_differs:@DEST" = "warning"\n"xml_schema.missing_element" = "ignore"')
	assert p.severity(.merge, 'value_differs', '@DEST') == .warning
	assert p.severity(.merge, 'value_differs', 'VT') == .error
	assert p.severity(.merge, 'in_conflict', '') == .warning
	assert p.severity(.xml_schema, 'missing_element', 'X') == .ignore
	assert p.severity(.xml_schema, 'unsupported', '') == .warning
	assert p.severity(.multiplicity, 'below_min', '') == .warning
	assert p.severity(.multiplicity, 'above_max', '') == .error
	// what a policy refuses, and the messages: policy_test.v
}

fn test_findings_of_every_layer() {
	mut m := load([vdata('invalid')])!
	defer {
		m.free()
	}
	c := check(m, compile_schemas(m, vdata('schemas')))!
	xml := c.findings.filter(it.layer == .xml_schema)
	assert xml.len > 0
	assert xml.any(it.kind == 'undeclared_element' && it.what == 'NOPE' && it.severity == .error
		&& it.path == '#LIBRARY/SHELVES/SHELF/NOPE' && it.at[0].ends_with('bad.arxml:6:7'))
	mult := c.findings.filter(it.layer == .multiplicity)
	// a shelf with no SHORT-NAME: below its fewest, a warning
	assert mult.any(it.kind == 'below_min' && it.what == 'SHORT-NAME' && it.severity == .warning
		&& it.path == '#LIBRARY/SHELVES/SHELF')
	// four notes where three are the most: the merge says too_many and keeps three, so the
	// merged model's count is within its most and nothing is said twice
	assert c.findings.any(it.layer == .merge && it.kind == 'too_many' && it.severity == .error)
	assert !mult.any(it.kind == 'above_max')
	assert c.times['merge'] > 0 && c.times['xml_schema'] > 0 && c.times['multiplicity'] > 0
	// layers can be skipped
	d := check(m, compile_schemas(m, vdata('schemas')), skip_xml: true, skip_multiplicity: true)!
	assert d.findings.all(it.layer == .merge)
}

fn test_severity_decides_what_fails() {
	mut m := load([vdata('merge')])!
	defer {
		m.free()
	}
	c := check(m, compile_schemas(m, vdata('schemas')))!
	assert c.count(.error) == 2
	p := vpolicy('"merge.value_differs:SHORT-NAME" = "warning"\n"merge.ordered_split" = "ignore"')
	d := check(m, compile_schemas(m, vdata('schemas'), policy: p))!
	assert d.count(.error) == 0 && d.count(.warning) == 1 && d.count(.ignore) == 1
}

fn test_choice_alternatives_have_no_fewest_in_that_holder_only() {
	// X, of one group, is an alternative in CHOOSING and required in PLAIN
	mut m := load([vdata('alt')])!
	defer {
		m.free()
	}
	c := check(m, compile_schemas(m, vdata('schemas')), skip_xml: true)!
	below := c.findings.filter(it.kind == 'below_min')
	assert below.len == 1
	assert below[0].path == '#TOP/PLAIN' && below[0].what == 'X'
}

fn test_no_xml_finding_is_lost_past_a_cap() {
	dir := os.join_path(os.temp_dir(), 'arxmodel_many_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	nopes := '<NOPE/>'.repeat(1500)
	os.write_file(os.join_path(dir, 'many.arxml'), '<LIBRARY xmlns="urn:arxmodel:test:lib" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:arxmodel:test:lib LIB_1.xsd">${nopes}</LIBRARY>')!
	mut m := load([dir])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, vdata('schemas'))
	one, _ := xml_findings(m, sc, 1)
	three, _ := xml_findings(m, sc, 3)
	assert one.len >= 1500 && one.len == three.len
	assert one.all(it.finding.severity == .error)
}

fn test_merge_severity_reaches_problems_in_conflict() {
	p := vpolicy('"merge.too_many:NOTE" = "ignore"')
	// a kind's line applies in conflict or not; else in_conflict; else the layer
	assert p.merge_severity('too_many', 'NOTE', true) == .ignore
	assert p.merge_severity('collision', 'X', true) == .warning
	assert p.merge_severity('collision', 'X', false) == .error
}

fn test_unknown_severity_kinds_and_attributes_are_refused() {
	// what flatxml cannot write is an error, not a crash
	f := Flat{}
	if _ := format_rules(f, Provenance{}, Settings{
		ignore_attrs: ['a b']
	}) {
		assert false
	}
}

fn test_wrappers_of_item_content_are_counted_as_unchecked() {
	mut m := load([vdata('invalid')])!
	defer {
		m.free()
	}
	c := check(m, compile_schemas(m, vdata('schemas')))!
	assert c.unchecked_roles == 1
}
