module arxmodel

import os

fn vdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

// values_by reads a model by the built-in identity rules and gives the values a pattern wants,
// as lines.
fn values_by(m &Model, pattern string, ignore []string) []string {
	p := automat_policy()
	c := check_with(m, identity_flat(builtin_identity(), [m]), 'built-in identity rules', p.settings(),
		p, CheckOptions{
			skip_xml:          true
			skip_multiplicity: true
			skip_references:   true
			ignore_elements:   ignore
		}) or { panic(err) }
	return c.values(pattern).map(it.line())
}

// values_model writes one document and loads it.
fn values_model(name string, text string) &Model {
	dir := os.join_path(os.temp_dir(), 'arxmodel_values_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	path := os.join_path(dir, name + '.arxml')
	os.write_file(path, text) or { panic(err) }
	return load([path]) or { panic(err) }
}

fn test_values_by_path() {
	m := load([vdata('compare')]) or { panic(err) }
	assert values_by(m, '/Body/**', []) == [
		'/Body/Head#WATTS = "55"',
		'/Body/Head#NOTES/NOTE = "first"',
		'/Body/Head#NOTES/NOTE = "second"',
		'/Body/LampCfg/Count = "2"',
		'/Body/LampCfg/Dim = "10"',
		'/Body/LampCfg/Signal = "/Sig/A"',
		'/Body/Tail#WATTS = "5"',
		'/Body/Tail#TARGET-REF = "/Body/Head"',
	]
	// a value named by its definition, wherever it is
	assert values_by(m, '/**/Dim', []) == ['/Body/LampCfg/Dim = "10"']
	// an element's path: every value below it
	assert values_by(m, '/Body/LampCfg', []) == ['/Body/LampCfg/Count = "2"', '/Body/LampCfg/Dim = "10"',
		'/Body/LampCfg/Signal = "/Sig/A"']
	// `*` one segment or part of one; `#` only by itself
	assert values_by(m, '/Body/*#WATTS', []) == ['/Body/Head#WATTS = "55"', '/Body/Tail#WATTS = "5"']
	assert values_by(m, '/Body/*/WATTS', []) == []
	assert values_by(m, '/Body/LampCfg/D*', []) == ['/Body/LampCfg/Dim = "10"']
	assert values_by(m, '/Nowhere/**', []) == []
	// elements whose content the merge does not compare are no values
	assert values_by(m, '/Body/Head', ['NOTES']) == ['/Body/Head#WATTS = "55"']
}

fn test_an_items_parts_its_label_and_quoting() {
	m := values_model('parts', '<MODEL><PACKAGES><PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>
<MODULE-VALUES><SHORT-NAME>Cfg</SHORT-NAME><DEFINITION-REF>/Defs/Cfg</DEFINITION-REF><PARAMETERS>
<NUMBER-PARAM-VALUE><NOTES><NOTE>n</NOTE></NOTES><DEFINITION-REF>/Defs/Cfg/Level</DEFINITION-REF><IS-AUTO>true</IS-AUTO><VALUE> 3 </VALUE></NUMBER-PARAM-VALUE>
<TEXT-PARAM-VALUE><DEFINITION-REF>/Defs/Cfg/Mode</DEFINITION-REF><VARIATION-POINT><SHORT-LABEL>v1</SHORT-LABEL></VARIATION-POINT><VALUE>a "b" \\ c</VALUE></TEXT-PARAM-VALUE>
</PARAMETERS></MODULE-VALUES></ELEMENTS></PACKAGE></PACKAGES></MODEL>')
	// the item's last element is its value; its other parts follow `#`; its label is a key; in
	// the merged view's order (its lists, keyed, before what is matched by place)
	assert values_by(m, '/P/**', []) == [
		'/P/Cfg/Level#NOTES/NOTE = "n"',
		'/P/Cfg/Level#IS-AUTO = "true"',
		'/P/Cfg/Level = "3"',
		'/P/Cfg/Mode[v1]#VARIATION-POINT/SHORT-LABEL = "v1"',
		'/P/Cfg/Mode[v1] = "a \\"b\\" \\\\ c"',
		'/P/Cfg#DEFINITION-REF = "/Defs/Cfg"',
	]
	assert values_by(m, '/P/Cfg/Level', ['NOTES']) == ['/P/Cfg/Level#IS-AUTO = "true"',
		'/P/Cfg/Level = "3"']
	// a pattern without a key matches a keyed segment by its name; with one, by both
	assert values_by(m, '/P/Cfg/Mode', []).len == 2
	assert values_by(m, '/P/Cfg/Mode[v1]', []).len == 2
	assert values_by(m, '/P/Cfg/Mode[v2]', []) == []
}

fn test_a_value_is_one_line() {
	assert Value{
		path: '/P/X'
		text: 'a"b\\c\nd\te\x01'
	}.line() == '/P/X = "a\\"b\\\\c\\nd\\te\\u0001"'
}
