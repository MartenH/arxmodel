module arxmodel

import flatxml
import os

fn source_of(path string, body string) Source {
	return Source{path, body.bytes()}
}

const open_a = '<AUTOSAR xmlns="urn:m"><AR-PACKAGES><AR-PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>' +
	'<THING><SHORT-NAME>A</SHORT-NAME><OTHER-REF DEST="THING">/P/B</OTHER-REF></THING>' +
	'</ELEMENTS></AR-PACKAGE></AR-PACKAGES></AUTOSAR>'

// the same package in a second file, the namespace bound to a prefix
const open_b = '<ar:AUTOSAR xmlns:ar="urn:m"><ar:AR-PACKAGES><ar:AR-PACKAGE><ar:SHORT-NAME>P</ar:SHORT-NAME><ar:ELEMENTS>' +
	'<ar:THING><ar:SHORT-NAME>B</ar:SHORT-NAME><ar:OTHER-REF DEST="THING" BASE="x">B</ar:OTHER-REF>' +
	'<ar:GONE-REF DEST="THING">/P/C</ar:GONE-REF></ar:THING>' +
	'</ar:ELEMENTS></ar:AR-PACKAGE></ar:AR-PACKAGES></ar:AUTOSAR>'

fn test_open_indexes_a_model_split_over_files() {
	mut o := open_sources([source_of('a.arxml', open_a), source_of('b.arxml', open_b)])!
	defer {
		o.free()
	}
	a := o.at('/P/A')
	b := o.at('/P/B')
	assert a.ok() && b.ok()
	assert o.path_of(b) == '/P/B'
	assert b.local_name() == 'THING'
	// one package, from both files
	assert o.at('/P').fragment_count() == 2
	assert o.of_kind('THING').map(o.path_of(it)) == ['/P/A', '/P/B']
	assert o.of_kind('AR-PACKAGE').len == 1
	assert o.of_kind('NOTHING').len == 0
	assert !o.at('/P/C').ok()
	assert o.pos(b).starts_with('b.arxml:1:')
}

fn test_open_follows_absolute_references_only() {
	mut o := open_sources([source_of('a.arxml', open_a), source_of('b.arxml', open_b)])!
	defer {
		o.free()
	}
	mut refs := map[string]string{}
	for t in o.of_kind('THING') {
		for c in t.children() {
			if c.local_name().ends_with('-REF') {
				refs['${o.path_of(t)} ${c.local_name()}'] = if n := o.target(c) {
					o.path_of(n)
				} else {
					'none'
				}
			}
		}
	}
	assert refs == {
		'/P/A OTHER-REF': '/P/B'
		'/P/B OTHER-REF': 'none' // relative, with BASE
		'/P/B GONE-REF':  'none' // dangling
	}
}

fn test_open_refuses_a_document_that_does_not_parse() {
	open_sources([source_of('bad.arxml', '<AUTOSAR>')]) or {
		assert err.msg().contains('bad.arxml')
		return
	}
	assert false
}

fn test_open_keeps_the_order_written_and_lists_what_one_file_repeats() {
	text := '<AUTOSAR xmlns="urn:m"><AR-PACKAGES><AR-PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>' +
		'<THING><SHORT-NAME>Z</SHORT-NAME></THING><THING><SHORT-NAME>A</SHORT-NAME></THING>' +
		'<THING><SHORT-NAME>Z</SHORT-NAME><V>1</V></THING></ELEMENTS></AR-PACKAGE></AR-PACKAGES></AUTOSAR>'
	mut o := open_sources([source_of('a.arxml', text)])!
	defer {
		o.free()
	}
	assert o.of_kind('THING').map(o.path_of(it)) == ['/P/Z', '/P/A']
	assert o.repeated.len == 1
	assert o.repeated[0].starts_with('/P/Z: a.arxml:1:')
	assert o.repeated[0].contains(', a.arxml:1:')
}

fn test_a_model_file_reads_its_paths_from_its_own_directory() {
	dir := os.join_path(os.temp_dir(), 'arxmodel_modelfile_${os.getpid()}')
	os.mkdir_all(os.join_path(dir, 'part')) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'part', 'a.arxml'), open_a)!
	os.write_file(os.join_path(dir, 'b.arxml'), open_b)!
	os.write_file(os.join_path(dir, 'old.arxml'), '<broken')!
	mf_path := os.join_path(dir, 'sys.arxmodel.toml')
	os.write_file(mf_path, 'paths = ["part/", "*.arxml"]\nexclude = ["old.arxml"]\n')!
	assert is_model_file(mf_path)
	mf := load_model_file(mf_path)!
	assert mf.paths == [os.join_path(dir, 'part/'), os.join_path(dir, '*.arxml')]
	mut o := open(mf.paths, OpenOptions{
		exclude: mf.exclude
	})!
	defer {
		o.free()
	}
	assert o.model.failed.len == 0
	assert o.model.files.len == 2
	assert o.rules == 'built-in identity rules'
	assert o.of_kind('THING').map(o.path_of(it)) == ['/P/B', '/P/A'] // sorted by path: b.arxml, part/a.arxml
}

fn test_a_model_file_refuses_what_it_does_not_know() {
	for text, want in {
		'':                                          '`paths` names no file'
		'paths = ["a"]\nschemas = "x"':              'unknown setting `schemas`'
		'paths = "a"':                               '`paths` takes a list of strings'
		'paths = ["a"]\nschema_dir = "d"\nrules = "r"': 'more than one given'
	} {
		parse_model_file(text, 'm.arxmodel.toml') or {
			assert err.msg().contains(want), err.msg()
			continue
		}
		assert false, text
	}
}

fn test_open_by_a_schema_dir_that_governs_nothing_is_an_error() {
	open_sources([source_of('a.arxml', open_a)], schema_dir: os.temp_dir()) or {
		assert err.msg().contains('no schema governs') || err.msg().contains('namespace'), err.msg()
		return
	}
	assert false
}

fn test_open_by_the_schema_the_files_declare() {
	files := [os.join_path(@VMODROOT, 'testdata', 'model', 'a.arxml'),
		os.join_path(@VMODROOT, 'testdata', 'model', 'sub', 'b.arxml')]
	mut o := open(files, schema_dir: os.join_path(@VMODROOT, 'testdata', 'schemas'))!
	defer {
		o.free()
	}
	assert o.rules == 'schema LIB_1.xsd'
	// one shelf, from both files, its items as first written
	assert o.at('/Fiction').fragment_count() == 2
	assert o.of_kind('BOOK').map(o.path_of(it)) == ['/Fiction/Dune']
	assert o.of_kind('MAGAZINE').map(o.path_of(it)) == ['/Fiction/Analog']
}

fn ecuc(prefix string, values []string) string {
	p := if prefix == '' { '' } else { prefix + ':' }
	ns := if prefix == '' { 'xmlns="urn:m"' } else { 'xmlns:${prefix}="urn:m"' }
	mut vs := ''
	for v in values {
		vs += '<${p}ECUC-NUMERICAL-PARAM-VALUE><${p}DEFINITION-REF>/D/p</${p}DEFINITION-REF><${p}VALUE>${v}</${p}VALUE></${p}ECUC-NUMERICAL-PARAM-VALUE>'
	}
	return '<${p}AUTOSAR ${ns}><${p}AR-PACKAGES><${p}AR-PACKAGE><${p}SHORT-NAME>P</${p}SHORT-NAME><${p}ELEMENTS>' +
		'<${p}ECUC-CONTAINER-VALUE><${p}SHORT-NAME>C</${p}SHORT-NAME><${p}PARAMETER-VALUES>${vs}</${p}PARAMETER-VALUES></${p}ECUC-CONTAINER-VALUE>' +
		'</${p}ELEMENTS></${p}AR-PACKAGE></${p}AR-PACKAGES></${p}AUTOSAR>'
}

fn named_count(o &Opened, local string) int {
	mut n := 0
	for i in 0 .. o.view.len() {
		if o.view.node(u32(i)).local_name() == local {
			n++
		}
	}
	return n
}

fn test_values_of_a_definition_given_twice_merge_whatever_the_prefix() {
	// a definition given twice is keyed by its values' content: the content's element names are
	// local names, so a prefix does not keep one value apart from itself
	mut o := open_sources([source_of('a.arxml', ecuc('', ['1', '2'])), source_of('b.arxml', ecuc('ar', ['1', '2']))])!
	defer {
		o.free()
	}
	assert named_count(o, 'ECUC-NUMERICAL-PARAM-VALUE') == 2
	assert o.findings.len == 0
}

fn vk_setting_doc(prefix string, value string) string {
	p := if prefix == '' { '' } else { prefix + ':' }
	ns := if prefix == '' { 'xmlns="urn:arxmodel:test:lib"' } else { 'xmlns:${prefix}="urn:arxmodel:test:lib"' }
	return '<?xml version="1.0" encoding="UTF-8"?>
<${p}LIBRARY ${ns} xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:arxmodel:test:lib LIB_1.xsd">
<${p}SHELVES><${p}SHELF><${p}SHORT-NAME>Fiction</${p}SHORT-NAME><${p}SETTINGS><${p}SETTING><${p}DEFINITION-REF>/d/x</${p}DEFINITION-REF><${p}VALUE>${value}</${p}VALUE></${p}SETTING></${p}SETTINGS></${p}SHELF></${p}SHELVES>
</${p}LIBRARY>'
}

fn open_policy_file(name string, text string) string {
	path := os.join_path(os.temp_dir(), 'arxmodel_open_${os.getpid()}_${name}.toml')
	os.write_file(path, text) or { panic(err) }
	return path
}

fn test_by_the_schema_a_value_is_identified_by_its_definition_whatever_the_prefix() {
	policy := open_policy_file('by_def', automat_policy_text.replace(open_identity_line,
		'item_identity = { "Shelf.setting" = "definition" }'))
	defer {
		os.rm(policy) or {}
	}
	mut o := open_sources([source_of('a.arxml', vk_setting_doc('', '1')),
		source_of('b.arxml', vk_setting_doc('l', '1'))], schema_dir: os.join_path(@VMODROOT, 'testdata', 'schemas'), policy: policy)!
	defer {
		o.free()
	}
	assert o.rules == 'schema LIB_1.xsd'
	assert named_count(o, 'SETTING') == 1
}

fn test_the_policy_filters_apply_to_what_open_found() {
	// one definition, two values: a value that differs, which the filter makes an error
	policy := open_policy_file('filter', automat_policy_text.replace(open_identity_line,
		'item_identity = { "Shelf.setting" = "definition" }') +
		'\n[[filter]]\nmatch = "merge.value_differs"\nseverity = "error"\n')
	defer {
		os.rm(policy) or {}
	}
	mut o := open_sources([source_of('a.arxml', vk_setting_doc('', '1')),
		source_of('b.arxml', vk_setting_doc('', '2'))], schema_dir: os.join_path(@VMODROOT, 'testdata', 'schemas'), policy: policy)!
	defer {
		o.free()
	}
	f := o.findings.filter(it.kind == 'value_differs')
	assert f.len == 1
	assert f[0].severity == .error && f[0].filter == 1
}

fn test_open_sources_reads_relative_filters_from_its_roots() {
	// a filter by a file relative to where the files came from, the documents given as bytes
	policy := open_policy_file('rootfilter', automat_policy_text.replace(open_identity_line,
		'item_identity = { "Shelf.setting" = "definition" }') +
		'\n[[filter]]\nmatch = "merge.value_differs"\nfile = "b.arxml"\nseverity = "error"\n')
	defer {
		os.rm(policy) or {}
	}
	root := os.join_path(os.temp_dir(), 'arxmodel_roots_${os.getpid()}')
	srcs := [source_of(os.join_path(root, 'a.arxml'), vk_setting_doc('', '1')),
		source_of(os.join_path(root, 'b.arxml'), vk_setting_doc('', '2'))]
	schemas := os.join_path(@VMODROOT, 'testdata', 'schemas')
	mut o := open_sources(srcs, schema_dir: schemas, policy: policy, roots: [root])!
	defer {
		o.free()
	}
	f := o.findings.filter(it.kind == 'value_differs')
	assert f.len == 1 && f[0].filter == 1 && f[0].severity == .error, f.str()
}

const open_identity_line = 'item_identity = { "EcucContainerValue.parameterValue" = "definition", "EcucContainerValue.referenceValue" = "definition" }'

fn test_an_element_of_another_namespace_is_not_the_models() {
	text := '<AUTOSAR xmlns="urn:m" xmlns:ext="urn:x"><AR-PACKAGES><AR-PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>' +
		'<THING><SHORT-NAME>A</SHORT-NAME></THING><ext:THING><ext:SHORT-NAME>Q</ext:SHORT-NAME></ext:THING>' +
		'</ELEMENTS></AR-PACKAGE></AR-PACKAGES></AUTOSAR>'
	mut o := open_sources([source_of('a.arxml', text)])!
	defer {
		o.free()
	}
	assert model_namespace([o.model]) == 'urn:m'
	assert o.of_kind('THING').map(o.path_of(it)) == ['/P/A']
	assert !o.at('/P/Q').ok()
}

fn test_check_merges_a_prefixed_file_by_the_schemas_namespace() {
	dir := os.join_path(os.temp_dir(), 'arxmodel_check_prefix_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'a.arxml'), vk_setting_doc('', '1'))!
	os.write_file(os.join_path(dir, 'b.arxml'), vk_setting_doc('l', '1'))!
	m := load([dir])!
	sc := compile_schemas(m, os.join_path(@VMODROOT, 'testdata', 'schemas'))
	c := check(m, sc, skip_xml: true, skip_references: true, skip_multiplicity: true)!
	mut shelves := 0
	for i in 0 .. c.view.len() {
		if c.view.node(u32(i)).name() == 'SHELF' {
			shelves++
		}
	}
	assert shelves == 1 // one shelf, from both files, as open merges it
}

fn test_the_models_namespace_is_most_roots_one() {
	foreign := '<x:AUTOSAR xmlns:x="urn:other"><x:AR-PACKAGES/></x:AUTOSAR>'
	mut o := open_sources([source_of('00.arxml', foreign), source_of('a.arxml', open_a), source_of('b.arxml', open_b)])!
	defer {
		o.free()
	}
	assert model_namespace([o.model]) == 'urn:m'
	assert o.at('/P/A').ok() && o.at('/P/B').ok()
	assert o.findings.any(it.kind == 'name_differs')
}

fn test_a_repetition_is_said_once() {
	pkg := '<AR-PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS><THING><SHORT-NAME>A</SHORT-NAME></THING></ELEMENTS></AR-PACKAGE>'
	mut o := open_sources([source_of('a.arxml', '<AUTOSAR xmlns="urn:m"><AR-PACKAGES>${pkg}${pkg}</AR-PACKAGES></AUTOSAR>')])!
	defer {
		o.free()
	}
	assert o.repeated.len == 1
	assert o.repeated[0].starts_with('/P: ')
}

fn test_an_element_of_no_namespace_is_no_value_of_the_model() {
	// {}VENDOR-PARAM-VALUE has the shape of an ECUC value's name and is not the model's
	text := '<AUTOSAR xmlns="urn:m"><AR-PACKAGES><AR-PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>' +
		'<ECUC-CONTAINER-VALUE><SHORT-NAME>C</SHORT-NAME><PARAMETER-VALUES><VENDOR-PARAM-VALUE xmlns=""><DEFINITION-REF>/D/p</DEFINITION-REF></VENDOR-PARAM-VALUE></PARAMETER-VALUES></ECUC-CONTAINER-VALUE>' +
		'</ELEMENTS></AR-PACKAGE></AR-PACKAGES></AUTOSAR>'
	mut o := open_sources([source_of('a.arxml', text)])!
	defer {
		o.free()
	}
	f := o.view.set.tab.id('{}VENDOR-PARAM-VALUE') or { panic('no expanded name') }
	mut x := &Identified{
		id: builtin_identity()
		nm: naming(model_namespace([o.model]), [o.model])
	}
	x.observe([o.model])
	facts := x.facts(o.model.set.docs[0].root_node()) or { panic('no facts') }
	assert !facts.by_def[f]
}

fn frame_doc(length string) string {
	return '<AUTOSAR xmlns="urn:m"><AR-PACKAGES><AR-PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>' +
		'<CAN-FRAME><SHORT-NAME>F</SHORT-NAME><FRAME-LENGTH>${length}</FRAME-LENGTH></CAN-FRAME>' +
		'</ELEMENTS></AR-PACKAGE></AR-PACKAGES></AUTOSAR>'
}

fn lengths_of(n flatxml.MNode) []flatxml.MNode {
	mut out := []flatxml.MNode{}
	for c in n.children() {
		if c.local_name() == 'FRAME-LENGTH' {
			out << c
		}
	}
	return out
}

fn test_files_giving_one_element_two_values_say_so() {
	// the one FRAME-LENGTH of a frame in each file is one element of the model: the first file's
	// is read, and that the second gives another is said
	mut o := open_sources([source_of('a.arxml', frame_doc('8')), source_of('b.arxml', frame_doc('12'))])!
	defer {
		o.free()
	}
	assert lengths_of(o.at('/P/F'))[0].text() == '8'
	d := o.findings.filter(it.kind == 'value_differs')
	assert d.len == 1 && d[0].path == '/P/F#FRAME-LENGTH' && d[0].at.len == 2, d.str()
	assert d[0].at[0].starts_with('a.arxml:') && d[0].at[1].starts_with('b.arxml:')
	// the same value in both, or the same element told apart by an attribute, is no finding
	mut same := open_sources([source_of('a.arxml', frame_doc('8')), source_of('b.arxml', frame_doc('8'))])!
	defer {
		same.free()
	}
	assert same.findings.len == 0, same.findings.str()
	// so is an element of the model a file gives other content: the second file's is not read
	desc := fn (l string, t string) string {
		return frame_doc('8').replace('</FRAME-LENGTH>', '</FRAME-LENGTH><DESC><L-2 L="${l}">${t}</L-2></DESC>')
	}
	mut langs := open_sources([source_of('a.arxml', desc('EN', 'hello')), source_of('b.arxml', desc('DE', 'hallo'))])!
	defer {
		langs.free()
	}
	assert langs.findings.map(it.path) == ['/P/F#DESC']
	// but elements told apart by an attribute are two
	label := fn (l string, t string) string {
		return frame_doc('8').replace('</FRAME-LENGTH>', '</FRAME-LENGTH><L-2 L="${l}">${t}</L-2>')
	}
	mut labels := open_sources([source_of('a.arxml', label('EN', 'hello')), source_of('b.arxml', label('DE', 'hallo'))])!
	defer {
		labels.free()
	}
	assert labels.findings.len == 0, labels.findings.str()
	// the attributes' order is nothing, nor a schema hint the merge ignores; what lies deeper is
	// content like the rest
	ref := fn (attrs string, path string) string {
		return frame_doc('8').replace('</FRAME-LENGTH>', '</FRAME-LENGTH><PDU-REF ${attrs}>${path}</PDU-REF>')
	}
	mut refs := open_sources([source_of('a.arxml', ref('DEST="I-PDU" BASE="b"', '/P/A')),
		source_of('b.arxml', ref('BASE="b" DEST="I-PDU"', '/P/B'))])!
	defer {
		refs.free()
	}
	assert refs.findings.map(it.path) == ['/P/F#PDU-REF']
	hinted := frame_doc('12').replace('<AUTOSAR xmlns="urn:m">', '<AUTOSAR xmlns="urn:m" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:m m.xsd">').replace('<FRAME-LENGTH>', '<FRAME-LENGTH xsi:schemaLocation="urn:m x.xsd">')
	mut hints := open_sources([source_of('a.arxml', frame_doc('8')), source_of('b.arxml', hinted)])!
	defer {
		hints.free()
	}
	assert hints.findings.map(it.path) == ['/P/F#FRAME-LENGTH'], hints.findings.str()
	mut deep := open_sources([source_of('a.arxml', desc('EN', 'hello')), source_of('b.arxml', desc('EN', 'hello').replace('L="EN"', 'L="DE"'))])!
	defer {
		deep.free()
	}
	assert deep.findings.map(it.path) == ['/P/F#DESC']
	// text is never taken for structure, and a CDATA boundary is no difference
	text_or := fn (body string) string {
		return frame_doc('8').replace('</FRAME-LENGTH>', '</FRAME-LENGTH><DESC>${body}</DESC>')
	}
	mut lit := open_sources([source_of('a.arxml', text_or('&lt;L-2&gt;hello')), source_of('b.arxml', text_or('<L-2>hello</L-2>'))])!
	defer {
		lit.free()
	}
	assert lit.findings.map(it.path) == ['/P/F#DESC']
	mut cdata := open_sources([source_of('a.arxml', text_or('a <![CDATA[b]]>')), source_of('b.arxml', text_or('a b'))])!
	defer {
		cdata.free()
	}
	assert cdata.findings.len == 0, cdata.findings.str()
	// named elements below are compared whatever their order, as the built-in rules merge them
	both := fn (first string, second string) string {
		return frame_doc('8').replace('</FRAME-LENGTH>', '</FRAME-LENGTH><MAPS><NOTE>n</NOTE>' +
			'<MAP><SHORT-NAME>${first}</SHORT-NAME></MAP><MAP><SHORT-NAME>${second}</SHORT-NAME></MAP></MAPS>')
	}
	mut order := open_sources([source_of('a.arxml', both('M1', 'M2')), source_of('b.arxml', both('M2', 'M1'))])!
	defer {
		order.free()
	}
	assert order.findings.len == 0, order.findings.str()
	mut other := open_sources([source_of('a.arxml', both('M1', 'M2')), source_of('b.arxml', both('M1', 'M3'))])!
	defer {
		other.free()
	}
	assert other.findings.map(it.path) == ['/P/F#MAPS']
	// and so are lists of them, keyed by their element name
	lists := fn (first string, second string) string {
		return frame_doc('8').replace('</FRAME-LENGTH>', '</FRAME-LENGTH><MAPS><NOTE>n</NOTE>' +
			'<${first}><M><SHORT-NAME>m</SHORT-NAME></M></${first}><${second}><M><SHORT-NAME>m</SHORT-NAME></M></${second}></MAPS>')
	}
	mut wrapped := open_sources([source_of('a.arxml', lists('XS', 'YS')), source_of('b.arxml', lists('YS', 'XS'))])!
	defer {
		wrapped.free()
	}
	assert wrapped.findings.len == 0, wrapped.findings.str()
	// nor is a name one file repeats: those are matched by place
	twice := frame_doc('8').replace('<FRAME-LENGTH>8</FRAME-LENGTH>', '<FRAME-LENGTH>8</FRAME-LENGTH><FRAME-LENGTH>9</FRAME-LENGTH>')
	mut rep := open_sources([source_of('a.arxml', twice), source_of('b.arxml', frame_doc('12'))])!
	defer {
		rep.free()
	}
	assert rep.findings.filter(it.kind == 'value_differs').len == 0
}

fn test_open_says_which_files_the_rules_came_from() {
	dir := os.join_path(os.temp_dir(), 'arxmodel_rule_files_${os.getpid()}')
	os.mkdir_all(os.join_path(dir, 'xsd', 'sub')) or { panic(err) }
	os.mkdir_all(os.join_path(dir, 'outside')) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// the schema, its extension in another case, imports one outside the schema directory
	lib := os.read_file(os.join_path(@VMODROOT, 'testdata', 'schemas', 'LIB_1', 'LIB_1.xsd'))!
	head := 'elementFormDefault="qualified">'
	os.write_file(os.join_path(dir, 'xsd', 'sub', 'LIB_1.Xsd'), lib.replace(head, head +
		'<xsd:import namespace="urn:other" schemaLocation="../../outside/O.xsd"/>'))!
	other := os.join_path(dir, 'outside', 'O.xsd')
	os.write_file(other, '<xsd:schema xmlns:xsd="http://www.w3.org/2001/XMLSchema" targetNamespace="urn:other"/>')!
	files := [os.join_path(@VMODROOT, 'testdata', 'model', 'a.arxml')]
	cfg := os.join_path(dir, 'config.toml')
	mut o := open(files, schema_dir: os.join_path(dir, 'xsd'), config: cfg)!
	defer {
		o.free()
	}
	assert o.rules == 'schema LIB_1.xsd'
	assert o.rule_files.map(os.real_path(it)) == [os.real_path(cfg),
		os.real_path(os.join_path(dir, 'xsd', 'sub', 'LIB_1.Xsd')), os.real_path(other)]
	// by a rules file, that file
	rules := os.join_path(dir, 'lib.rules.txt')
	mut m := load(files)!
	sc := compile_schemas(m, os.join_path(dir, 'xsd'), policy: named_policy('spec')!)
	flat, name := governing_flat(sc)!
	u := sc.uses.filter(it.name == name)[0]
	os.write_file(rules, format_rules(flat, provenance(u, sc.policy), sc.policy.settings())!)!
	m.free()
	mut r := open(files, rules_file: rules)!
	defer {
		r.free()
	}
	assert r.rule_files == [rules]
	// and a policy file, whatever the rules
	pol := os.join_path(dir, 'p.toml')
	os.write_file(pol, default_policy_text)!
	mut rp := open(files, rules_file: rules, policy: pol)!
	defer {
		rp.free()
	}
	assert rp.rule_files == [pol, rules]
	// and by the built-in rules, none
	mut b := open(files)!
	defer {
		b.free()
	}
	assert b.rule_files.len == 0
}
