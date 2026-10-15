module arxmodel

import flatxml
import os
import x.json2

fn rdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

fn test_a_location_is_read_from_the_right() {
	assert parse_location('a/b.arxml:3:14') == Location{'a/b.arxml', 3, 14}
	assert parse_location('C:\\m\\b.arxml:3:14') == Location{'C:\\m\\b.arxml', 3, 14}
	assert parse_location('b.arxml') == Location{
		file: 'b.arxml'
	}
	assert parse_location('C:\\m\\b.arxml') == Location{
		file: 'C:\\m\\b.arxml'
	}
}

fn test_strings_and_file_names_are_escaped() {
	assert jstr('a"b\\c\nd\x01') == '"a\\"b\\\\c\\nd\\u0001"'
	assert file_uri('m/a b#1.arxml') == 'm/a%20b%231.arxml'
	assert file_uri('/m/a.arxml') == 'file:///m/a.arxml'
	assert file_uri('C:\\m\\a.arxml') == 'file:///C:/m/a.arxml'
	assert file_uri('\\\\srv\\share\\a.arxml') == 'file://srv/share/a.arxml'
	assert xattr('<a & "b">\n\t') == '&lt;a &amp; &quot;b&quot;&gt;&#10;&#9;'
	assert xtext('a\r\n<b>\x01') == 'a&#13;\n&lt;b&gt;'
}

fn test_bytes_that_are_not_utf8_are_replaced() {
	latin1 := 'm/caf\xe9.arxml' // a Latin-1 file name
	assert utf8_or_replaced(latin1) == 'm/caf\uFFFD.arxml'
	assert utf8_or_replaced('m/café.arxml') == 'm/café.arxml'
	// overlong, a surrogate, past U+10FFFF, cut short
	for bad in ['\xc0\xaf', '\xed\xa0\x80', '\xf4\x90\x80\x80', '\xe2\x82'] {
		assert !utf8_or_replaced(bad).contains_any('\xc0\xed\xf4\xe2'), bad.bytes().hex()
	}
	r := Report{
		command:    'check'
		first_file: latin1
		inputs:     [not_read(latin1, '${latin1}:3:9: end tag')]
		findings:   [
			Finding{
				layer:    .merge
				kind:     'value_differs'
				severity: .error
				path:     '/x\xff'
				message:  'differs'
				at:       ['${latin1}:1:2']
			},
		]
	}
	doc := json2.decode[json2.Any](r.json())!.as_map()
	assert doc['inputs']!.as_array()[0].as_map()['file']!.str() == 'm/caf\uFFFD.arxml'
	json2.decode[json2.Any](r.sarif())!
	mut d := flatxml.parse_string(r.junit())!
	d.free()
}

fn test_a_file_not_read_keeps_where_the_parser_stopped() {
	p := not_read('m/bad.arxml', 'm/bad.arxml:2:49: end tag </A> does not match <B>')
	assert p.line == 2 && p.column == 49
	q := not_read('m/dir', 'm/dir: cannot read directory')
	assert q.line == 0 && q.column == 0
}

fn test_the_default_threads_are_at_most_eight() {
	assert default_jobs() >= 1 && default_jobs() <= 8
	assert jobs_or_default(12) == 12
	assert jobs_or_default(0) == default_jobs()
}

// checked_report is check's report of the files at dir, a directory of testdata.
fn checked_report(dir string) !Report {
	mut m := load([rdata(dir)])!
	sc := compile_schemas(m, rdata('schemas'), policy: automat_policy())
	c := check(m, sc)!
	return check_report(m, sc, c)
}

fn test_the_json_report_holds_every_finding_and_location() {
	r := checked_report('merge')!
	assert r.findings.len == 2 && r.tally().errors == 2 && r.failed()
	doc := json2.decode[json2.Any](r.json())!.as_map()
	assert doc['version']!.int() == report_version
	assert doc['command']!.str() == 'check'
	summary := doc['summary']!.as_map()
	assert summary['errors']!.int() == 2
	assert summary['layers']!.as_array().map(it.str()) == ['merge', 'xml_schema', 'multiplicity',
		'reference']
	fs := doc['findings']!.as_array()
	assert fs.len == r.findings.len
	for k, f in fs {
		g := f.as_map()
		want := r.findings[k]
		assert g['rule']!.str() == '${want.layer}.${want.kind}'
		assert g['severity']!.str() == 'error'
		locs := g['locations']!.as_array()
		assert locs.len == want.at.len && locs.len == 2
		for l in locs {
			lm := l.as_map()
			assert lm['file']!.str().ends_with('.arxml')
			assert lm['line']!.int() > 0 && lm['column']!.int() > 0
		}
	}
}

fn test_files_not_checked_are_in_every_report() {
	r := checked_report('model')!
	assert r.findings.len == 0 && r.failed()
	assert r.inputs.map(it.kind) == ['not_read', 'undeclared']
	assert r.inputs[0].line == 2 && r.inputs[0].column == 49
	doc := json2.decode[json2.Any](r.json())!.as_map()
	assert doc['inputs']!.as_array().len == 2
	sarif := json2.decode[json2.Any](r.sarif())!.as_map()
	results := sarif['runs']!.as_array()[0].as_map()['results']!.as_array()
	assert results.len == 2
	assert results.map(it.as_map()['ruleId']!.str()) == ['input.not_read', 'input.undeclared']
	assert r.junit().count('<failure ') == 2
}

fn test_the_sarif_report_has_a_result_per_finding_and_a_rule_per_kind() {
	r := checked_report('merge')!
	doc := json2.decode[json2.Any](r.sarif())!.as_map()
	assert doc['version']!.str() == '2.1.0'
	assert doc['\$schema']!.str().contains('sarif-schema-2.1.0')
	run := doc['runs']!.as_array()[0].as_map()
	rules := run['tool']!.as_map()['driver']!.as_map()['rules']!.as_array()
	assert rules.map(it.as_map()['id']!.str()) == ['merge.value_differs', 'merge.ordered_split']
	results := run['results']!.as_array()
	assert results.len == r.findings.len
	for res in results {
		m := res.as_map()
		assert m['level']!.str() == 'error'
		assert rules[m['ruleIndex']!.int()].as_map()['id']!.str() == m['ruleId']!.str()
		locs := m['locations']!.as_array()
		assert locs.len == 2
		// every result has a physical location
		assert locs.all(it.as_map()['physicalLocation']!.as_map()['artifactLocation']!.as_map()['uri']!.str() != '')
		for l in locs {
			region := l.as_map()['physicalLocation']!.as_map()['region']!.as_map()
			assert region['startLine']!.int() >= 1 && region['startColumn']!.int() >= 1
		}
	}
}

fn test_ignored_findings_are_left_out_of_sarif_and_junit() {
	r := Report{
		command:  'check'
		layers:   ['merge']
		findings: [
			Finding{
				layer:    .merge
				kind:     'value_differs'
				severity: .ignore
				path:     '/a'
				message:  'differs'
				at:       ['a.arxml:1:1']
			},
			Finding{
				layer:    .merge
				kind:     'name_differs'
				severity: .warning
				path:     '/b'
				message:  'differs'
				at:       ['a.arxml:2:1']
			},
		]
	}
	assert !r.failed()
	assert json2.decode[json2.Any](r.json())!.as_map()['findings']!.as_array().len == 2
	sarif := json2.decode[json2.Any](r.sarif())!.as_map()
	results := sarif['runs']!.as_array()[0].as_map()['results']!.as_array()
	assert results.len == 1 && results[0].as_map()['level']!.str() == 'warning'
	j := r.junit()
	assert !j.contains('value_differs') && !j.contains('<failure')
	assert j.contains('<system-out>')
}

fn test_the_junit_report_has_a_case_per_kind_failing_on_errors() {
	r := checked_report('merge')!
	mut d := flatxml.parse_string(r.junit())!
	defer {
		d.free()
	}
	root := d.root_node()
	assert root.name() == 'testsuites'
	assert root.attr('tests') == '5' && root.attr('failures') == '2'
	suite := root.child('testsuite')
	assert suite.ok()
	mut names := []string{}
	mut failing := 0
	for c in suite.children() {
		names << c.attr('name')
		if c.child('failure').ok() {
			failing++
		}
	}
	// the two kinds found, and the three layers that found nothing
	assert names == ['merge.value_differs', 'merge.ordered_split', 'xml_schema', 'multiplicity',
		'reference']
	assert failing == 2
}

fn test_a_model_no_schema_governs_is_reported_as_an_input() {
	mut m := load([rdata('model', 'a.arxml')])!
	r := input_report(m, 'no schema governs urn:x')
	assert r.failed()
	assert r.inputs.map(it.kind) == ['ungoverned']
	assert r.inputs[0].file.ends_with('a.arxml')
	sarif := json2.decode[json2.Any](r.sarif())!.as_map()
	res := sarif['runs']!.as_array()[0].as_map()['results']!.as_array()
	assert res.len == 1 && res[0].as_map()['ruleId']!.str() == 'input.ungoverned'
	assert r.junit().contains('name="input.ungoverned"')
}

fn test_a_finding_on_no_place_is_placed_in_the_model_s_first_file() {
	r := Report{
		command:    'check'
		first_file: 'm/a.arxml'
		findings:   [
			Finding{
				layer:    .merge
				kind:     'conflict'
				severity: .warning
				path:     'P/C'
				message:  'holders with different rules'
			},
		]
	}
	sarif := json2.decode[json2.Any](r.sarif())!.as_map()
	loc := sarif['runs']!.as_array()[0].as_map()['results']!.as_array()[0].as_map()['locations']!.as_array()[0].as_map()
	assert loc['physicalLocation']!.as_map()['artifactLocation']!.as_map()['uri']!.str() == 'm/a.arxml'
	assert r.tally() == Tally{0, 1, 0}
}
