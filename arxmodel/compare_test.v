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

fn test_merge3_a_removal_takes_a_node_only_its_uuid_changed_on() {
	tail := '<LAMP UUID="u2">
          <SHORT-NAME>Tail</SHORT-NAME>
          <WATTS>5</WATTS>
          <TARGET-REF DEST="LAMP">/Body/Head</TARGET-REF>
        </LAMP>'
	base := version_of('base')
	uuid := version_of('uuid', 'UUID="u2"', 'UUID="u9"')
	gone := version_of('gone', tail, '')
	watts := version_of('watts', '<WATTS>5</WATTS>', '<WATTS>7</WATTS>')
	r, v := builtin_versions(base, uuid, gone, watts)
	// whichever side changed the UUID, the node goes, with no conflict
	mut ours := r.merge3(&v[0], &v[1], &v[2])!
	assert ours.conflicts.len == 0
	assert !ours.m3.edit.doc_edit(0).xml().contains('<SHORT-NAME>Tail</SHORT-NAME>')
	mut theirs := r.merge3(&v[0], &v[2], &v[1])!
	assert theirs.conflicts.len == 0
	assert !theirs.m3.edit.doc_edit(0).xml().contains('<SHORT-NAME>Tail</SHORT-NAME>')
	// a change the model holds still conflicts with the removal
	assert r.merge3(&v[0], &v[3], &v[2])!.conflicts.len == 1
}

fn test_merge3_decisions_take_a_side_and_are_tied_to_the_conflict() {
	base := version_of('base')
	ours := version_of('ours', '<WATTS>55</WATTS>', '<WATTS>60</WATTS>', '<WATTS>5</WATTS>',
		'<WATTS>6</WATTS>')
	theirs := version_of('theirs', '<WATTS>55</WATTS>', '<WATTS>65</WATTS>', '<WATTS>5</WATTS>',
		'<WATTS>7</WATTS>')
	later := version_of('later', '<WATTS>55</WATTS>', '<WATTS>66</WATTS>', '<WATTS>5</WATTS>',
		'<WATTS>7</WATTS>')
	r, v := builtin_versions(base, ours, theirs, later)
	plain := r.merge3(&v[0], &v[1], &v[2])!
	assert plain.conflicts.len == 2
	head, tail := plain.conflicts[0], plain.conflicts[1]
	assert head.id.len == 16 && head.id != tail.id
	assert head.base.value or { '' } == '55' && head.ours.value or { '' } == '60'
		&& head.theirs.value or { '' } == '65'
	assert head.ours.xml.starts_with('<LAMP UUID="u1">\n          <SHORT-NAME>Head')
	assert head.ours.xml.ends_with('</LAMP>') && !head.ours.cut

	mut one := r.merge3(&v[0], &v[1], &v[2], decisions: {
		head.id: Take.theirs
	})!
	assert one.conflicts.map(it.id) == [tail.id] && one.resolved == 1 && one.unused == []
	text := one.m3.edit.doc_edit(0).xml()
	assert text.contains('<WATTS>65</WATTS>') && text.contains('<WATTS>6</WATTS>')

	mut both := r.merge3(&v[0], &v[1], &v[2], decisions: {
		head.id: Take.theirs
		tail.id: Take.ours
	})!
	assert both.conflicts.len == 0 && both.resolved == 2

	// theirs changed since: not the conflict decided, so the decision does not apply
	mut stale := r.merge3(&v[0], &v[1], &v[3], decisions: {
		head.id: Take.theirs
	})!
	assert stale.conflicts.len == 2 && stale.unused == [head.id] && stale.resolved == 0
	assert stale.m3.edit.doc_edit(0).xml().contains('<WATTS>60</WATTS>')

	// a decision that is no id is said like one that went stale
	assert r.merge3(&v[0], &v[1], &v[2], decisions: {
		'aa': Take.ours
	})!.unused == ['aa']
}

fn test_merge3_a_removal_has_no_side_where_it_is_gone() {
	tail := '<LAMP UUID="u2">
          <SHORT-NAME>Tail</SHORT-NAME>
          <WATTS>5</WATTS>
          <TARGET-REF DEST="LAMP">/Body/Head</TARGET-REF>
        </LAMP>'
	base := version_of('base')
	gone := version_of('gone', tail, '')
	watts := version_of('watts', '<WATTS>5</WATTS>', '<WATTS>7</WATTS>')
	r, v := builtin_versions(base, gone, watts)
	mut m := r.merge3(&v[0], &v[1], &v[2])!
	assert m.conflicts.len == 1
	c := m.conflicts[0]
	assert c.ours_at == '-' && c.ours.xml == ''
	assert c.theirs.xml.contains('<WATTS>7</WATTS>')
	report := m.json()
	assert report.contains('"ours":null') && report.contains('"kind":"removed"')
	// theirs gives the node back, with its change
	mut back := r.merge3(&v[0], &v[1], &v[2], decisions: {
		c.id: Take.theirs
	})!
	assert back.conflicts.len == 0
	assert back.m3.edit.doc_edit(0).xml().contains('<WATTS>7</WATTS>')
}

// lamp_head is the base's Head, to take out of its package and put back elsewhere.
const lamp_head = '<LAMP UUID="u1">
          <SHORT-NAME>Head</SHORT-NAME>
          <WATTS>55</WATTS>
          <NOTES><NOTE>first</NOTE><NOTE>second</NOTE></NOTES>
        </LAMP>'

fn test_a_decision_on_a_removal_does_not_cover_a_later_change_below() {
	base := version_of('base')
	gone := version_of('gone', lamp_head, '')
	one := version_of('one', '<WATTS>55</WATTS>', '<WATTS>60</WATTS>')
	two := version_of('two', '<WATTS>55</WATTS>', '<WATTS>60</WATTS>', '<NOTE>first</NOTE>',
		'<NOTE>new</NOTE>')
	r, v := builtin_versions(base, gone, one, two)
	// ours removes it: ours decided on one change of theirs
	id := r.merge3(&v[0], &v[1], &v[2])!.conflicts[0].id
	kept := r.merge3(&v[0], &v[1], &v[3], decisions: {
		id: Take.ours
	})!
	assert kept.conflicts.len == 1 && kept.unused == [id]
	// and the report says all that the decision covers
	assert kept.conflicts[0].theirs.changes == ['~ /Body/Head#WATTS: "55" -> "60"',
		'~ /Body/Head#NOTES/NOTE: "first" -> "new"']
	// theirs removes it: theirs decided on one change of ours
	back := r.merge3(&v[0], &v[2], &v[1])!.conflicts[0].id
	dropped := r.merge3(&v[0], &v[3], &v[1], decisions: {
		back: Take.theirs
	})!
	assert dropped.conflicts.len == 1 && dropped.unused == [back]
}

fn test_a_decision_on_a_removal_counts_the_order_of_what_is_added() {
	notes := '<NOTE>first</NOTE><NOTE>second</NOTE>'
	base := version_of('base')
	gone := version_of('gone', lamp_head, '')
	ab := version_of('ab', '<WATTS>55</WATTS>', '<WATTS>60</WATTS>', notes, notes +
		'<NOTE>a</NOTE><NOTE>b</NOTE>')
	ba := version_of('ba', '<WATTS>55</WATTS>', '<WATTS>60</WATTS>', notes, notes +
		'<NOTE>b</NOTE><NOTE>a</NOTE>')
	r, v := builtin_versions(base, gone, ab, ba)
	id := r.merge3(&v[0], &v[1], &v[2])!.conflicts[0].id
	assert r.merge3(&v[0], &v[1], &v[3], decisions: {
		id: Take.theirs
	})!.unused == [id]
}

fn test_a_decision_on_a_move_is_tied_to_where_it_goes() {
	// three packages, Head moved into the one named
	packages := fn (to string) string {
		mut out := ''
		for name in ['Q', 'R', 'S'] {
			inside := if name == to { lamp_head } else { '' }
			out += '<PACKAGE><SHORT-NAME>${name}</SHORT-NAME><ELEMENTS>${inside}</ELEMENTS></PACKAGE>\n'
		}
		return out + '</PACKAGES>'
	}
	base := version_of('base', '</PACKAGES>', packages(''))
	q := version_of('q', lamp_head, '', '</PACKAGES>', packages('Q'))
	r_ := version_of('r', lamp_head, '', '</PACKAGES>', packages('R'))
	s_ := version_of('s', lamp_head, '', '</PACKAGES>', packages('S'))
	r, v := builtin_versions(base, q, r_, s_)
	c := r.merge3(&v[0], &v[1], &v[2])!.conflicts[0]
	assert c.kind == .moved
	later := r.merge3(&v[0], &v[1], &v[3], decisions: {
		c.id: Take.theirs
	})!
	assert later.conflicts.len == 1 && later.unused == [c.id]
}

fn test_items_of_a_list_are_decided_apart() {
	base := version_of('base')
	ours := version_of('ours', '<NOTE>first</NOTE><NOTE>second</NOTE>', '<NOTE>x</NOTE><NOTE>x</NOTE>')
	theirs := version_of('theirs', '<NOTE>first</NOTE><NOTE>second</NOTE>', '<NOTE>y</NOTE><NOTE>y</NOTE>')
	r, v := builtin_versions(base, ours, theirs)
	cs := r.merge3(&v[0], &v[1], &v[2])!.conflicts
	assert cs.len == 2 && cs[0].id != cs[1].id
	mut one := r.merge3(&v[0], &v[1], &v[2], decisions: {
		cs[1].id: Take.theirs
	})!
	assert one.conflicts.map(it.id) == [cs[0].id] && one.resolved == 1
	assert one.m3.edit.doc_edit(0).xml().contains('<NOTE>x</NOTE><NOTE>y</NOTE>')
}

fn test_variants_of_one_path_are_decided_apart() {
	label := fn (l string) string {
		return '<SHORT-NAME>Head</SHORT-NAME><VARIATION-POINT><SHORT-LABEL>${l}</SHORT-LABEL></VARIATION-POINT>'
	}
	two := ['<SHORT-NAME>Head</SHORT-NAME>', label('a'), '<SHORT-NAME>Tail</SHORT-NAME>', label('b'),
		'<WATTS>5</WATTS>', '<WATTS>55</WATTS>']
	base := version_of('base', ...two)
	mut to_60 := two.clone()
	to_60 << ['<WATTS>55</WATTS>', '<WATTS>60</WATTS>']
	mut to_65 := two.clone()
	to_65 << ['<WATTS>55</WATTS>', '<WATTS>65</WATTS>']
	ours := version_of('ours', ...to_60)
	theirs := version_of('theirs', ...to_65)
	r, v := builtin_versions(base, ours, theirs)
	cs := r.merge3(&v[0], &v[1], &v[2])!.conflicts
	assert cs.len == 2 && cs[0].path == cs[1].path && cs[0].id != cs[1].id
}

fn test_an_addition_over_several_files_is_all_in_its_id() {
	dir := os.join_path(os.temp_dir(), 'arxmodel_fragments_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	pkg := fn (inner string) string {
		return '<PACKAGE><SHORT-NAME>New</SHORT-NAME><ELEMENTS>${inner}</ELEMENTS></PACKAGE>'
	}
	lamp := fn (name string) string {
		return '<LAMP UUID="${name}"><SHORT-NAME>${name}</SHORT-NAME></LAMP>'
	}
	part := fn [dir, pkg, lamp] (name string, inner string) string {
		path := os.join_path(dir, name + '.arxml')
		os.write_file(path, '<MODEL><PACKAGES>${pkg(lamp(inner))}</PACKAGES></MODEL>') or {
			panic(err)
		}
		return path
	}
	base := version_of('base')
	ours := version_of('ours', '</PACKAGES>', pkg(lamp('O')) + '</PACKAGES>')
	main := version_of('main', '</PACKAGES>', pkg(lamp('T')) + '</PACKAGES>').set.docs[0].path
	theirs := load([main, part('one', 'A')])!
	later := load([main, part('two', 'B')])!
	r, v := builtin_versions(base, ours, theirs, later)
	id := r.merge3(&v[0], &v[1], &v[2])!.conflicts[0].id
	assert id != r.merge3(&v[0], &v[1], &v[3])!.conflicts[0].id
}

fn test_a_context_past_the_limit_is_the_node_then_its_start() {
	long := '<NOTE>' + 'x'.repeat(context_limit) + '</NOTE>'
	base := version_of('base')
	ours := version_of('ours', '<WATTS>55</WATTS>', '<WATTS>60</WATTS>', '<NOTE>second</NOTE>',
		long)
	theirs := version_of('theirs', '<WATTS>55</WATTS>', '<WATTS>65</WATTS>')
	r, v := builtin_versions(base, ours, theirs)
	c := r.merge3(&v[0], &v[1], &v[2])!.conflicts[0]
	// the parent is too long on ours's side alone
	assert c.ours.xml == '<WATTS>60</WATTS>' && !c.ours.cut
	assert c.theirs.xml.starts_with('<LAMP UUID="u1">')
	big := version_of('big', '<WATTS>55</WATTS>', '<WATTS>' + 'y'.repeat(context_limit) + '</WATTS>')
	s, w := builtin_versions(base, big, theirs)
	d := s.merge3(&w[0], &w[1], &w[2])!.conflicts[0]
	assert d.ours.cut && d.ours.xml.len == context_limit
}

fn test_parse_decisions() {
	got := parse_decisions('# what was decided\ntheirs aa  # a path\n\n  ours bb\nours bb\n')!
	assert got == {
		'aa': Take.theirs
		'bb': Take.ours
	}
	if _ := parse_decisions('both cc') {
		assert false
	} else {
		assert err.msg().contains('line 1')
	}
	if _ := parse_decisions('ours\n') {
		assert false
	}
	if _ := parse_decisions('ours cc\ntheirs cc\n') {
		assert false
	} else {
		assert err.msg().contains('line 2') && err.msg().contains('both ways')
	}
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
