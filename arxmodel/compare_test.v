module arxmodel

import flatxml
import os

fn cdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

// version_of writes a variant of the base model (each pair a replacement) and loads it.
fn version_of(name string, edits ...string) &Model {
	mut text := os.read_file(cdata('compare', 'base.arxml')) or { panic(err) }
	for k := 0; k + 1 < edits.len; k += 2 {
		assert text.contains(edits[k]), edits[k]
		text = text.replace(edits[k], edits[k + 1])
	}
	dir := os.join_path(os.temp_dir(), 'arxmodel_compare_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	path := os.join_path(dir, name + '.arxml')
	os.write_file(path, text) or { panic(err) }
	return load([path]) or { panic(err) }
}

fn builtin_versions(models ...&Model) (Ruling, []Version) {
	r := ruling_builtin(models, automat_policy().settings(), CheckOptions{})
	return r, models.map(r.read(it) or { panic(err) })
}

fn change_lines(cs []PathChange) []string {
	return cs.map(it.line().all_before('  '))
}

fn test_the_built_in_identity() {
	id := builtin_identity()
	assert id.name == ['SHORT-NAME', 'VARIATION-POINT/SHORT-LABEL']
	assert id.definition == 'DEFINITION-REF'
	assert glob('*-PARAM-VALUE', 'NUMBER-PARAM-VALUE') && !glob('*-PARAM-VALUE', 'PARAM-VALUES')
	for text, says in {
		'[identity]\nname = []\nby_definition = []\ndefinition = "D"':              'names no path'
		'[identity]\nname = ["S"]\nby_definition = []':                             '`identity.definition` is not set'
		'[identity]\nname = ["S"]\nby_definition = []\ndefinition = "D"\nmore = 1': 'unknown setting `identity.more`'
		'[other]':                                                                  'unknown table [other]'
		'[identity]\nname = "S"\nby_definition = []\ndefinition = "D"':             '`identity.name` takes a list of strings'
	} {
		parse_identity(text) or {
			assert err.msg().contains(says), err.msg()
			continue
		}
		assert false, says
	}
}

fn test_keys_by_the_built_in_identity() {
	mut d := flatxml.parse_string('<R><L><X><SHORT-NAME>A</SHORT-NAME><VARIATION-POINT><SHORT-LABEL>v</SHORT-LABEL></VARIATION-POINT></X><Y><SHORT-NAME>B</SHORT-NAME></Y></L><P><N-PARAM-VALUE><DEFINITION-REF>/d/x</DEFINITION-REF><VARIATION-POINT><SHORT-LABEL>w</SHORT-LABEL></VARIATION-POINT></N-PARAM-VALUE><N-PARAM-VALUE><DEFINITION-REF>/d/m</DEFINITION-REF><VALUE>1</VALUE></N-PARAM-VALUE><N-PARAM-VALUE><DEFINITION-REF>/d/m</DEFINITION-REF><VALUE>2</VALUE></N-PARAM-VALUE></P><T>t</T><M><T>1</T><Y><SHORT-NAME>C</SHORT-NAME></Y></M><E/></R>') or {
		panic(err)
	}
	mut m := empty_model()
	m.set.add(mut d)
	mut x := &Identified{
		id: builtin_identity()
	}
	x.observe([m])
	r := d.root_node()
	s := flatxml.key_sep
	assert x.key(r.at('L/X'))? == 'A${s}v'
	assert x.key(r.at('L/Y'))? == 'B${s}'
	// a value by its definition and its variation point's label
	assert x.key(r.at('P/N-PARAM-VALUE'))? == '${s}/d/x${s}w'
	// a definition given twice under one parent: a set, each value by its content too
	assert x.multi.keys() == ['/d/m${s}']
	mut ms := []flatxml.Node{}
	for c in r.at('P').children() {
		if c.at('DEFINITION-REF').text() == '/d/m' {
			ms << c
		}
	}
	assert x.key(ms[0])? == '/d/m${s}${s}VALUE=1' && x.key(ms[1])? == '/d/m${s}${s}VALUE=2'
	// a list of named elements is one list; anything else is matched by its place
	assert x.key(r.at('L'))? == '${s}L' && x.key(r.at('P'))? == '${s}P'
	assert x.key(r.at('T')) == none && x.key(r.at('M')) == none
	// an element named like a list another document holds is the list, even when empty
	x.lists['E'] = true
	assert x.key(r.at('E'))? == '${s}E'
}

fn test_a_diff_names_changes_by_path() {
	base := version_of('base')
	ours := version_of('ours', '<WATTS>55</WATTS>', '<WATTS>60</WATTS>', 'UUID="u1"', 'UUID="x1"',
		'<VALUE>10</VALUE>', '<VALUE>12</VALUE>')
	r, v := builtin_versions(base, ours)
	assert change_lines(r.diff(&v[0], &v[1])) == ['~ /Body/Head#WATTS: "55" -> "60"',
		'~ /Body/LampCfg#PARAMETERS/NUMBER-PARAM-VALUE[,/Defs/Lamp/Dim,]/VALUE: "10" -> "12"']
	assert r.diff(&v[0], &v[0]).len == 0
}

fn test_order_counts_only_for_unnamed_elements() {
	base := version_of('base')
	text := os.read_file(cdata('compare', 'base.arxml'))!
	head := text[text.index('        <LAMP UUID="u1">')?..text.index('        <LAMP UUID="u2">')?]
	tail := text[text.index('        <LAMP UUID="u2">')?..text.index('        <MODULE-VALUES>')?]
	// the named lamps swapped: no change; the unnamed notes swapped: a move
	swapped := version_of('swapped', head + tail, tail + head)
	notes := version_of('notes', '<NOTE>first</NOTE><NOTE>second</NOTE>', '<NOTE>second</NOTE><NOTE>first</NOTE>')
	r, v := builtin_versions(base, swapped, notes)
	assert r.diff(&v[0], &v[1]).len == 0
	assert change_lines(r.diff(&v[0], &v[2])) == ['> /Body/Head#NOTES/NOTE -> /Body/Head#NOTES/NOTE']
}

fn test_merge3_takes_both_sides_or_names_the_conflict() {
	base := version_of('base')
	ours := version_of('ours', '<WATTS>55</WATTS>', '<WATTS>60</WATTS>')
	theirs := version_of('theirs', '<WATTS>5</WATTS>', '<WATTS>7</WATTS>', '<VALUE>10</VALUE>',
		'<VALUE>12</VALUE>')
	clash := version_of('clash', '<WATTS>55</WATTS>', '<WATTS>65</WATTS>')
	r, v := builtin_versions(base, ours, theirs, clash)
	mut clean := r.merge3(&v[0], &v[1], &v[2])!
	assert clean.conflicts.len == 0
	text := clean.m3.edit.doc_edit(0).xml()
	assert text.contains('<WATTS>60</WATTS>') && text.contains('<WATTS>7</WATTS>')
		&& text.contains('<VALUE>12</VALUE>')
	conflicted := r.merge3(&v[0], &v[1], &v[3])!
	assert conflicted.conflicts.map(it.line().all_before('  ')) == ['! /Body/Head#WATTS: text "60" / "65"']
}

fn test_versions_read_by_the_schema() {
	// the exact rules: the LIB schema's, the release the versions declare
	mut a := load([cdata('merge')])!
	mut b := load([cdata('merge')])!
	r := ruling_by_schema([a, b], cdata('schemas'), automat_policy(), CheckOptions{})!
	assert r.name == 'LIB_1.xsd' && !r.builtin
	va, vb := r.read(a)!, r.read(b)!
	assert r.diff(&va, &vb).len == 0
}

fn test_the_configured_schema_dir() {
	assert parse_config('schema_dir = "xsd"', '/home/u/.config/arxmodel/config.toml')! == '/home/u/.config/arxmodel/xsd'
	assert parse_config('schema_dir = "/opt/autosar"', 'c.toml')! == '/opt/autosar'
	parse_config('schema = "x"', 'c.toml') or {
		assert err.msg() == 'c.toml: unknown setting `schema`'
		return
	}
	assert false
}

fn test_check_by_the_built_in_rules() {
	// the merge layer and the references, by their DEST: an unnamed element is matched by its
	// place by design, so it is no missing key
	m := load([cdata('compare')])!
	p := automat_policy()
	c := check_with(m, identity_flat(builtin_identity(), [m]), 'built-in identity rules', p.settings(),
		p, CheckOptions{})!
	assert c.refs.checked == 5
	assert c.findings.map('${it.layer}.${it.kind} ${it.path}') == [
		'reference.external /Body/LampCfg#PARAMETERS/NUMBER-PARAM-VALUE[,/Defs/Lamp/Count,]/DEFINITION-REF',
		'reference.external /Body/LampCfg#PARAMETERS/NUMBER-PARAM-VALUE[,/Defs/Lamp/Dim,]/DEFINITION-REF',
		'reference.external /Body/LampCfg#REFERENCES/SIGNAL-REFERENCE-VALUE[,/Defs/Lamp/Signal,]/DEFINITION-REF',
		'reference.external /Body/LampCfg#REFERENCES/SIGNAL-REFERENCE-VALUE[,/Defs/Lamp/Signal,]/VALUE-REF',
	]
	// files loaded only to resolve references against, with no schema too
	sig := os.join_path(os.temp_dir(), 'arxmodel_sig_${os.getpid()}.arxml')
	os.write_file(sig, '<MODEL><PACKAGES><PACKAGE><SHORT-NAME>Sig</SHORT-NAME><ELEMENTS><SIGNAL><SHORT-NAME>A</SHORT-NAME></SIGNAL></ELEMENTS></PACKAGE></PACKAGES></MODEL>')!
	d := check_with(m, identity_flat(builtin_identity(), [m]), 'built-in identity rules', p.settings(),
		p, CheckOptions{ refs_from: [sig] })!
	assert d.refs_from_files == 1 && d.findings.len == 3
	assert !d.findings.any(it.path.ends_with('VALUE-REF'))
}

fn test_values_of_one_definition() {
	sig_a := '<VALUE-REF DEST="SIGNAL">/Sig/A</VALUE-REF>
            </SIGNAL-REFERENCE-VALUE>'
	add := fn (sig string) string {
		return '<VALUE-REF DEST="SIGNAL">/Sig/A</VALUE-REF>
            </SIGNAL-REFERENCE-VALUE>
            <SIGNAL-REFERENCE-VALUE>
              <DEFINITION-REF DEST="REF-DEF">/Defs/Lamp/Signal</DEFINITION-REF>
              <VALUE-REF DEST="SIGNAL">/Sig/${sig}</VALUE-REF>
            </SIGNAL-REFERENCE-VALUE>'
	}
	base := version_of('base')
	// a reference given several values: each side adding one is no conflict, and the values stay
	// apart
	ours := version_of('ours', sig_a, add('B'))
	theirs := version_of('theirs', sig_a, add('C'))
	// one value both sides change differently: a conflict
	dim_o := version_of('dim_o', '<VALUE>10</VALUE>', '<VALUE>12</VALUE>')
	dim_t := version_of('dim_t', '<VALUE>10</VALUE>', '<VALUE>13</VALUE>')
	r, v := builtin_versions(base, ours, theirs, dim_o, dim_t)
	mut both := r.merge3(&v[0], &v[1], &v[2])!
	assert both.conflicts.len == 0
	text := both.m3.edit.doc_edit(0).xml()
	assert text.count('<SIGNAL-REFERENCE-VALUE>') == 3 && text.count('</SIGNAL-REFERENCE-VALUE>') == 3
	for sig in ['A', 'B', 'C'] {
		assert text.contains('<VALUE-REF DEST="SIGNAL">/Sig/${sig}</VALUE-REF>\n            </SIGNAL-REFERENCE-VALUE>')
	}
	one := r.merge3(&v[0], &v[3], &v[4])!
	assert one.conflicts.map(it.line().all_before('  ')) == ['! /Body/LampCfg#PARAMETERS/NUMBER-PARAM-VALUE[,/Defs/Lamp/Dim,]/VALUE: text "12" / "13"']
}

fn test_an_emptied_list_is_the_list() {
	text := os.read_file(cdata('compare', 'base.arxml'))!
	inside := text[text.index('<ELEMENTS>')? + '<ELEMENTS>'.len..text.index('</ELEMENTS>')?]
	base := version_of('base')
	empty := version_of('empty', inside, '')
	r, v := builtin_versions(base, empty)
	assert change_lines(r.diff(&v[0], &v[1])) == ['- /Body/Head', '- /Body/LampCfg', '- /Body/Tail']
}

fn test_ignored_elements_are_no_change() {
	sig_a := '<VALUE-REF DEST="SIGNAL">/Sig/A</VALUE-REF>
            </SIGNAL-REFERENCE-VALUE>'
	// a reference given two values (a set, its values told apart by their content)
	two := fn [sig_a] (note string) string {
		return sig_a + '
            <SIGNAL-REFERENCE-VALUE>${note}
              <DEFINITION-REF DEST="REF-DEF">/Defs/Lamp/Signal</DEFINITION-REF>
              <VALUE-REF DEST="SIGNAL">/Sig/B</VALUE-REF>
            </SIGNAL-REFERENCE-VALUE>'
	}
	note := '<NOTES><NOTE>derived</NOTE></NOTES>'
	old := version_of('ig_old', sig_a, two(''))
	// the same values, a note added to one of the set and to a value of one definition
	new := version_of('ig_new', sig_a, two(note), '<VALUE>10</VALUE>', '${note}<VALUE>10</VALUE>')
	r, v := builtin_versions(old, new)
	compared := change_lines(r.diff(&v[0], &v[1]))
	assert compared.any(it.starts_with('- /Body/LampCfg#REFERENCES/SIGNAL-REFERENCE-VALUE'))
	assert compared.any(it.contains('/NOTES'))
	ri := ruling_builtin([old, new], automat_policy().settings(), CheckOptions{
		ignore_elements: ['NOTES']
	})
	a, b := ri.read(old)!, ri.read(new)!
	assert ri.diff(&a, &b) == []
}
