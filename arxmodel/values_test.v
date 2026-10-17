module arxmodel

import os

fn vdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

// values_by reads a model by the built-in identity rules and gives the values a pattern wants,
// as lines.
fn values_by(m &Model, pattern string) []string {
	p := automat_policy()
	c := check_with(m, identity_flat(builtin_identity(), [m]), 'built-in identity rules', p.settings(),
		p, CheckOptions{
			skip_xml:          true
			skip_multiplicity: true
			skip_references:   true
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
	assert values_by(m, '/Body/**') == [
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
	assert values_by(m, '/**/Dim') == ['/Body/LampCfg/Dim = "10"']
	// an element's path: every value below it
	assert values_by(m, '/Body/LampCfg') == ['/Body/LampCfg/Count = "2"', '/Body/LampCfg/Dim = "10"',
		'/Body/LampCfg/Signal = "/Sig/A"']
	// `*` one segment or part of one; `#` only by itself
	assert values_by(m, '/Body/*#WATTS') == ['/Body/Head#WATTS = "55"', '/Body/Tail#WATTS = "5"']
	assert values_by(m, '/Body/*/WATTS') == []
	assert values_by(m, '/Body/LampCfg/D*') == ['/Body/LampCfg/Dim = "10"']
	assert values_by(m, '/Nowhere/**') == []
}

fn test_an_items_parts_its_label_and_quoting() {
	m := values_model('parts', '<MODEL><PACKAGES><PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>
<MODULE-VALUES><SHORT-NAME>Cfg</SHORT-NAME><DEFINITION-REF>/Defs/Cfg</DEFINITION-REF><PARAMETERS>
<NUMBER-PARAM-VALUE><NOTES><NOTE>n</NOTE></NOTES><DEFINITION-REF>/Defs/Cfg/Level</DEFINITION-REF><IS-AUTO>true</IS-AUTO><VALUE> 3 </VALUE></NUMBER-PARAM-VALUE>
<TEXT-PARAM-VALUE><DEFINITION-REF>/Defs/Cfg/Mode</DEFINITION-REF><VARIATION-POINT><SHORT-LABEL>v1</SHORT-LABEL></VARIATION-POINT><VALUE>a "b" \\ c</VALUE></TEXT-PARAM-VALUE>
</PARAMETERS></MODULE-VALUES></ELEMENTS></PACKAGE></PACKAGES></MODEL>')
	// the item's last element is its value; its other parts follow `#`; its label is a key; in
	// the merged view's order (its lists, keyed, before what is matched by place)
	assert values_by(m, '/P/**') == [
		'/P/Cfg/Level#NOTES/NOTE = "n"',
		'/P/Cfg/Level#IS-AUTO = "true"',
		'/P/Cfg/Level = "3"',
		'/P/Cfg/Mode[v1]#VARIATION-POINT/SHORT-LABEL = "v1"',
		'/P/Cfg/Mode[v1] = "a \\"b\\" \\\\ c"',
		'/P/Cfg#DEFINITION-REF = "/Defs/Cfg"',
	]
	// a pattern without a key matches a keyed segment by its name; with one, by both
	assert values_by(m, '/P/Cfg/Mode').len == 2
	assert values_by(m, '/P/Cfg/Mode[v1]').len == 2
	assert values_by(m, '/P/Cfg/Mode[v2]') == []
}

fn test_a_value_is_one_line() {
	assert Value{
		path: '/P/X'
		text: 'a"b\\c\nd\te\x01'
	}.line() == '/P/X = "a\\"b\\\\c\\nd\\te\\u0001"'
}

fn test_a_container_is_no_item_and_an_item_needs_its_definition() {
	// by the built-in rules a container is named by its definition and by its short name: its
	// short name is its path, not a value; an item giving no definition is not named by one
	m := values_model('container', '<MODEL><PACKAGES><PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>
<MODULE-VALUES><SHORT-NAME>Cfg</SHORT-NAME><CONTAINERS>
<ECUC-CONTAINER-VALUE><SHORT-NAME>C</SHORT-NAME><DEFINITION-REF>/Defs/C</DEFINITION-REF><PARAMETER-VALUES>
<NUMBER-PARAM-VALUE><DEFINITION-REF>/Defs/C/Level</DEFINITION-REF><VALUE>1</VALUE></NUMBER-PARAM-VALUE>
<NUMBER-PARAM-VALUE><DEFINITION-REF></DEFINITION-REF><VALUE>5</VALUE></NUMBER-PARAM-VALUE>
</PARAMETER-VALUES></ECUC-CONTAINER-VALUE>
</CONTAINERS></MODULE-VALUES></ELEMENTS></PACKAGE></PACKAGES></MODEL>')
	vals := values_by(m, '/P/**')
	assert '/P/Cfg/C/Level = "1"' in vals
	assert '/P/Cfg/C#DEFINITION-REF = "/Defs/C"' in vals
	assert !vals.any(it.contains('SHORT-NAME'))
	assert !vals.any(it.contains('/ = ') || it.contains('C/#'))
	assert vals.any(it.starts_with('/P/Cfg/C#PARAMETER-VALUES/NUMBER-PARAM-VALUE')
		&& it.ends_with('/VALUE = "5"'))
}

fn test_the_root_pattern() {
	m := load([vdata('compare')]) or { panic(err) }
	// `/` is the root: every value
	assert values_by(m, '/') == values_by(m, '/**')
	assert values_by(m, '/').len == 8
}

fn test_the_value_of_an_item_split_over_files() {
	// one file gives the item a part, another its value: the value is the value
	dir := os.join_path(os.temp_dir(), 'arxmodel_values_${os.getpid()}', 'split_item')
	os.mkdir_all(dir) or { panic(err) }
	for name, part in {
		'a': '<IS-AUTO>true</IS-AUTO>'
		'b': '<VALUE>3</VALUE>'
	} {
		os.write_file(os.join_path(dir, '${name}.arxml'), '<MODEL><PACKAGES><PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>
<MODULE-VALUES><SHORT-NAME>Cfg</SHORT-NAME><PARAMETERS>
<NUMBER-PARAM-VALUE><DEFINITION-REF>/Defs/Cfg/Level</DEFINITION-REF>${part}</NUMBER-PARAM-VALUE>
</PARAMETERS></MODULE-VALUES></ELEMENTS></PACKAGE></PACKAGES></MODEL>') or {
			panic(err)
		}
	}
	m := load([dir]) or { panic(err) }
	assert values_by(m, '/P/**') == ['/P/Cfg/Level#IS-AUTO = "true"', '/P/Cfg/Level = "3"']
}

fn test_two_files_giving_an_item_its_value() {
	// by the built-in rules each file's value is a child of its own: the first file's is the value
	dir := os.join_path(os.temp_dir(), 'arxmodel_values_${os.getpid()}', 'two_values')
	os.mkdir_all(dir) or { panic(err) }
	for name, value in {
		'a': '2'
		'b': '3'
	} {
		os.write_file(os.join_path(dir, '${name}.arxml'), '<MODEL><PACKAGES><PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>
<MODULE-VALUES><SHORT-NAME>Cfg</SHORT-NAME><PARAMETERS>
<NUMBER-PARAM-VALUE><DEFINITION-REF>/Defs/Cfg/Level</DEFINITION-REF><VALUE>${value}</VALUE></NUMBER-PARAM-VALUE>
</PARAMETERS></MODULE-VALUES></ELEMENTS></PACKAGE></PACKAGES></MODEL>') or {
			panic(err)
		}
	}
	m := load([dir]) or { panic(err) }
	// the other file's copy is no value of its own (check reports that the files disagree)
	assert values_by(m, '/P/**') == ['/P/Cfg/Level = "2"']
}

fn test_values_written_side_by_side_and_several_of_one_definition() {
	m := values_model('side_by_side', '<MODEL><PACKAGES><PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>
<MODULE-VALUES><SHORT-NAME>Cfg</SHORT-NAME><PARAMETERS>
<NUMBER-PARAM-VALUE><DEFINITION-REF>/Defs/Cfg/Level</DEFINITION-REF><VALUE>1</VALUE><VALUE>2</VALUE></NUMBER-PARAM-VALUE>
<NUMBER-PARAM-VALUE><DEFINITION-REF>/Defs/Cfg/Mode</DEFINITION-REF><VALUE>a</VALUE></NUMBER-PARAM-VALUE>
<NUMBER-PARAM-VALUE><DEFINITION-REF>/Defs/Cfg/Mode</DEFINITION-REF><VALUE>b</VALUE></NUMBER-PARAM-VALUE>
</PARAMETERS></MODULE-VALUES></ELEMENTS></PACKAGE></PACKAGES></MODEL>')
	vals := values_by(m, '/P/**')
	// two values one item writes side by side: both printed, no copy of another file's
	assert '/P/Cfg/Level#VALUE = "1"' in vals && '/P/Cfg/Level = "2"' in vals, vals.str()
	// one definition given two values: each by its place
	assert '/P/Cfg/Mode[#1] = "a"' in vals && '/P/Cfg/Mode[#2] = "b"' in vals, vals.str()
	assert values_by(m, '/P/Cfg/Mode[#2]') == ['/P/Cfg/Mode[#2] = "b"']
}
