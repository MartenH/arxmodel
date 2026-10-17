module arxmodel

import flatxml
import flatxml.xsd
import os

// The specification's merge (the default policy) against the automat profile, each behaviour on
// synthetic documents of the test schema.

// lib_files writes documents, each a library whose shelf Fiction holds `shelf` (written in the
// shelf's content order) after `before` at the library's top, and loads them.
fn lib_files(name string, docs ...[]string) &Model {
	dir := os.join_path(os.temp_dir(), 'arxmodel_spec_${os.getpid()}', name)
	os.mkdir_all(dir) or { panic(err) }
	for k, d in docs {
		os.write_file(os.join_path(dir, '${k}.arxml'), '<?xml version="1.0" encoding="UTF-8"?>
<LIBRARY xmlns="urn:arxmodel:test:lib" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:arxmodel:test:lib LIB_1.xsd">
${d[0]}<SHELVES><SHELF><SHORT-NAME>Fiction</SHORT-NAME>${d[1]}</SHELF></SHELVES>
</LIBRARY>') or {
			panic(err)
		}
	}
	return load([dir]) or { panic(err) }
}

fn checked_by(m &Model, p Policy) Checked {
	sc := compile_schemas(m, os.join_path(@VMODROOT, 'testdata', 'schemas'), policy: p)
	return check(m, sc, skip_xml: true, skip_references: true, skip_multiplicity: true) or {
		panic(err)
	}
}

fn count_named(c Checked, name string) int {
	mut n := 0
	for i in 0 .. c.view.len() {
		if c.view.node(u32(i)).name() == name {
			n++
		}
	}
	return n
}

fn test_items_named_by_the_role_alone_are_copied() {
	// [TPS_GST_00417]: a multi-valued role whose split key is the role alone
	copy := '<COPIES><COPY><EDITION>1</EDITION></COPY></COPIES>'
	m := lib_files('copy', ['', copy], ['', copy])
	assert count_named(checked_by(m, default_policy()), 'COPY') == 2
	assert count_named(checked_by(m, automat_policy()), 'COPY') == 1
}

fn test_primitive_values_are_copied_duplicates_kept() {
	// [TPS_GST_00449]: every value of every fragment, duplicates too
	tag := '<ITEMS><BOOK><SHORT-NAME>Dune</SHORT-NAME><TAG-SET><TAG>a</TAG></TAG-SET></BOOK></ITEMS>'
	m := lib_files('tags', ['', tag], ['', tag])
	assert count_named(checked_by(m, default_policy()), 'TAG') == 2
	assert count_named(checked_by(m, automat_policy()), 'TAG') == 1
}

fn test_a_non_splittable_role_repeats_identically() {
	// [constr_2524], [TPS_GST_00447]: PALLETS is not splittable
	pallets := fn (what string) string {
		return '<ITEMS><BOOK><SHORT-NAME>Dune</SHORT-NAME><PALLETS><PALLET><CONTENTS><ITEM>${what}</ITEM></CONTENTS></PALLET></PALLETS></BOOK></ITEMS>'
	}
	same := lib_files('same', ['', pallets('sand')], ['', pallets('sand')])
	c := checked_by(same, default_policy())
	assert count_named(c, 'PALLET') == 1 && !c.findings.any(it.layer == .merge)
	differ := lib_files('differ', ['', pallets('sand')], ['', pallets('spice')])
	d := checked_by(differ, default_policy())
	assert d.findings.filter(it.kind == 'repeated_differs').map(it.path) == ['/Fiction/Dune#PALLETS']
	// a document's own duplicates stay: identical items of one document are two
	twice := lib_files('twice', ['',
		pallets('sand').replace('</PALLET>', '</PALLET><PALLET><CONTENTS><ITEM>sand</ITEM></CONTENTS></PALLET>')])
	assert count_named(checked_by(twice, default_policy()), 'PALLET') == 2
	// automat: each kept, nothing said
	a := checked_by(differ, automat_policy())
	assert !a.findings.any(it.kind == 'repeated_differs')
}

fn test_a_structured_comment_is_not_compared() {
	// [TPS_GST_00382]: FILE-NOTE is an atpStructuredComment
	m := lib_files('note', ['<FILE-NOTE>one</FILE-NOTE>', ''], [
		'<FILE-NOTE>two</FILE-NOTE>',
		'',
	])
	assert !checked_by(m, default_policy()).findings.any(it.kind == 'value_differs')
	assert checked_by(m, automat_policy()).findings.any(it.kind == 'value_differs'
		&& it.path == '#LIBRARY/FILE-NOTE')
}

fn test_items_of_several_types_take_the_union_of_their_keys() {
	// [TPS_GST_00416], under single_values keys so the types' keys differ
	s := xsd.load(os.join_path(@VMODROOT, 'testdata', 'schemas', 'LIB_1', 'LIB_1.xsd'))!
	mut p := automat_policy()
	per_kind := read_rules_with(s, p)
	p.abstract_items = .@union
	unioned := read_rules_with(s, p)
	keys := fn (rs &RuleSet, item string) []string {
		for r in rs.rules {
			for it in r.items {
				if it.element == item {
					return it.key.map(it.str())
				}
			}
		}
		return []
	}
	assert keys(per_kind, 'DISC') == ['TITLE'] && keys(per_kind, 'TAPE') == ['LABEL-TEXT']
	assert keys(unioned, 'DISC') == ['TITLE', 'LABEL-TEXT'] && keys(unioned, 'TAPE') == [
		'TITLE',
		'LABEL-TEXT',
	]
}

fn test_absent_keys_stay_apart_by_the_specification() {
	// [TPS_GST_00417]: a LOAN with no key part in each of two files
	mut m := load([os.join_path(@VMODROOT, 'testdata', 'absent')])!
	assert count_named(checked_by(m, default_policy()), 'LOAN') == 2
	assert count_named(checked_by(m, automat_policy()), 'LOAN') == 1
}

fn test_a_rules_file_keeps_what_the_policy_made() {
	m := lib_files('rules', ['', ''])
	p := default_policy()
	sc := compile_schemas(m, os.join_path(@VMODROOT, 'testdata', 'schemas'), policy: p)
	flat, name := governing_flat(sc)!
	assert flat.repeat_rules.len > 0 && flat.ignored_content == ['FILE-NOTE']
	u := sc.uses.filter(it.name == name)[0]
	text := format_rules(flat, provenance(u, p), p.settings())!
	back, pv, _ := parse_rules_file(text)!
	assert back.repeat_rules == flat.repeat_rules && back.ignored_content == flat.ignored_content
	assert 'item_itself copy' in pv.policy && 'file_info_comment ignore' in pv.policy
	// the merge settings a rules file carries come back: its namespace, and !written — and the
	// namespace is a `!local` setting, so flatxml reading the file alone merges as arxmodel does
	assert back.rules.local_ns == u.ns
	assert text.contains('\n!local ${u.ns}\n')
	assert flatxml.parse_rules(text)!.local_ns == u.ns
	mut written := flat
	written.rules = flatxml.RuleSet{
		...flat.rules
		written_order: true
	}
	back2, _, _ := parse_rules_file(format_rules(written, provenance(u, p), p.settings())!)!
	assert back2.rules.written_order
}

fn test_each_node_by_the_rule_applied_to_it() {
	// TAG under the shelf's TAG-SET (TagsA: not splittable) and under a book's (TagsB:
	// splittable) share the parent name TAG-SET; only the shelf's must repeat identically
	tags := fn (shelf string, book string) string {
		return '<ITEMS><BOOK><SHORT-NAME>Dune</SHORT-NAME><TAG-SET><TAG>${book}</TAG></TAG-SET></BOOK></ITEMS><TAG-SET><TAG>${shelf}</TAG></TAG-SET>'
	}
	books := lib_files('books', ['', tags('a', 'x')], ['', tags('a', 'y')])
	assert !checked_by(books, default_policy()).findings.any(it.kind == 'repeated_differs')
	// the shelf's is ordered: in two documents that is an ordered split, which flatxml says
	shelves := lib_files('shelves', ['', tags('a', 'x')], ['', tags('b', 'x')])
	c := checked_by(shelves, default_policy())
	assert c.findings.filter(it.kind == 'ordered_split').map(it.path) == ['/Fiction#TAG-SET']
}

fn test_content_hashes() {
	mut ch := new_content_hashes(['UUID'], Naming{})
	hash := fn [mut ch] (xml string) u64 {
		d := flatxml.parse_string(xml) or { panic(err) }
		return ch.hash(d.root_node())
	}
	// mixed content: the text beside the children counts
	assert hash('<A>x<B/></A>') != hash('<A>y<B/></A>')
	assert hash('<A>x<B/></A>') != hash('<A><B/>x</A>')
	// attributes in any order, those that may differ left out, indentation no text
	assert hash('<A p="1" q="2"/>') == hash('<A q="2" p="1"/>')
	assert hash('<A UUID="1"/>') == hash('<A UUID="2"/>')
	assert hash('<A>\n  <B>1</B>\n</A>') == hash('<A><B>1</B></A>')
	assert hash('<A><B>1</B></A>') != hash('<A><B>2</B></A>')
}

fn test_content_hashes_name_elements_as_the_merge_does() {
	mut ch := new_content_hashes([], Naming{
		ns: 'urn:m'
	})
	hash := fn [mut ch] (xml string) u64 {
		mut d := flatxml.parse_string(xml) or { panic(err) }
		d.resolve_namespaces() or { panic(err) }
		return ch.hash(d.root_node())
	}
	// the model's namespace by local names, whatever the prefix; another namespace as written
	assert hash('<A xmlns="urn:m"><B>1</B></A>') == hash('<m:A xmlns:m="urn:m"><m:B>1</m:B></m:A>')
	assert hash('<A xmlns="urn:m"><B>1</B></A>') != hash('<A xmlns="urn:m" xmlns:e="urn:e"><e:B>1</e:B></A>')
	// an attribute in a namespace by its expanded name, whatever its prefix
	assert hash('<A xmlns="urn:m" xmlns:p="urn:x" p:id="1"/>') == hash('<A xmlns="urn:m" xmlns:q="urn:x" q:id="1"/>')
}

fn test_an_attribute_ignored_by_one_spelling_is_left_out_of_every_hash() {
	// p:id is ignored; q:id, bound to the same URI, is that attribute too
	mk := fn (xml string) &flatxml.Doc {
		mut d := flatxml.parse_string(xml) or { panic(err) }
		d.resolve_namespaces() or { panic(err) }
		return d
	}
	a := mk('<A xmlns="urn:m" xmlns:p="urn:x" p:id="1"/>')
	b := mk('<A xmlns="urn:m" xmlns:q="urn:x" q:id="2"/>')
	mut set := flatxml.DocSet.new()
	mut da := a
	mut db := b
	set.add(mut da)
	set.add(mut db)
	m := &Model{
		set: set
	}
	mut ch := new_content_hashes(['p:id'], Naming{
		ns: 'urn:m'
	})
	ch.observe_ignored([m])
	assert ch.hash(set.docs[0].root_node()) == ch.hash(set.docs[1].root_node())
}

fn test_an_item_keyed_by_content_is_shown_by_its_place() {
	pallets := '<ITEMS><BOOK><SHORT-NAME>Dune</SHORT-NAME><PALLETS><PALLET><CONTENTS><ITEM>a</ITEM></CONTENTS></PALLET><PALLET><CONTENTS><ITEM>b</ITEM></CONTENTS></PALLET></PALLETS></BOOK></ITEMS>'
	c := checked_by(lib_files('places', ['', pallets]), default_policy())
	mut paths := []string{}
	for i in 0 .. c.view.len() {
		n := c.view.node(u32(i))
		if n.name() == 'PALLET' {
			paths << merged_path(n, c.index)
		}
	}
	assert paths == ['/Fiction/Dune#PALLETS/PALLET[#1]', '/Fiction/Dune#PALLETS/PALLET[#2]']
}

fn test_case_only_is_about_short_names() {
	// two settings whose definitions differ in case: not short names, nothing said
	p := parse_policy(default_policy_text.replace('item_identity = { "EcucContainerValue.parameterValue" = "definition", "EcucContainerValue.referenceValue" = "definition" }',
		'item_identity = { "Shelf.setting" = "definition" }'))!
	m := lib_files('defs', ['',
		'<SETTINGS><SETTING><DEFINITION-REF>/d/x</DEFINITION-REF><VALUE>1</VALUE></SETTING><SETTING><DEFINITION-REF>/D/X</DEFINITION-REF><VALUE>1</VALUE></SETTING></SETTINGS>'])
	assert !checked_by(m, p).findings.any(it.kind == 'case_only')
}

fn test_a_parent_written_twice_may_repeat_the_role() {
	// one document writes the book twice, each with the same pallets: allowed
	pallets := '<PALLETS><PALLET><CONTENTS><ITEM>a</ITEM></CONTENTS></PALLET></PALLETS>'
	twice := '<ITEMS><BOOK><SHORT-NAME>Dune</SHORT-NAME>${pallets}</BOOK></ITEMS></SHELF><SHELF><SHORT-NAME>Fiction</SHORT-NAME><ITEMS><BOOK><SHORT-NAME>Dune</SHORT-NAME>${pallets}</BOOK></ITEMS>'
	c := checked_by(lib_files('twice_parent', ['', twice]), default_policy())
	assert !c.findings.any(it.kind in ['collision', 'repeated_differs']), c.findings.map(it.str()).str()
}

fn test_merge3_keeps_ours_in_a_structured_comment() {
	dir := os.join_path(@VMODROOT, 'testdata', 'schemas')
	base := lib_files('n_base', ['<FILE-NOTE>base</FILE-NOTE>', ''])
	ours := lib_files('n_ours', ['<FILE-NOTE>ours</FILE-NOTE>', ''])
	theirs := lib_files('n_theirs', ['<FILE-NOTE>theirs</FILE-NOTE>', ''])
	for p in [default_policy(), automat_policy()] {
		r := ruling_by_schema([base, ours, theirs], dir, p, CheckOptions{})!
		b, o, t := r.read(base)!, r.read(ours)!, r.read(theirs)!
		m := r.merge3(&b, &o, &t)!
		assert m.conflicts.len == if p.ignore_structured { 0 } else { 1 }
	}
}

fn test_union_keeps_the_types_whose_key_resolved() {
	// MEDIA's DISC has a TITLE, its TAPE none: identified by a role only DISC has
	s := xsd.load(os.join_path(@VMODROOT, 'testdata', 'schemas', 'LIB_1', 'LIB_1.xsd'))!
	mut p := default_policy()
	p.item_identity = {
		'Shelf.medium': 'title'
	}
	rs := read_rules_with(s, p)
	for r in rs.rules {
		if r.element == 'MEDIA' {
			disc := r.items.filter(it.element == 'DISC')[0]
			tape := r.items.filter(it.element == 'TAPE')[0]
			assert !disc.key_lost && disc.key.map(it.str()) == ['TITLE']
			assert tape.key_lost
		}
	}
}

fn test_case_only_leaves_out_a_shelf_missing_its_key() {
	dir := os.join_path(os.temp_dir(), 'arxmodel_spec_${os.getpid()}', 'cases')
	os.mkdir_all(dir)!
	os.write_file(os.join_path(dir, 'a.arxml'), '<?xml version="1.0" encoding="UTF-8"?>
<LIBRARY xmlns="urn:arxmodel:test:lib" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:arxmodel:test:lib LIB_1.xsd">
<SHELVES><SHELF><SHORT-NAME>Fiction</SHORT-NAME></SHELF><SHELF><SHORT-NAME>fiction</SHORT-NAME></SHELF><SHELF/></SHELVES>
</LIBRARY>')!
	c := checked_by(load([dir])!, default_policy())
	co := c.findings.filter(it.kind == 'case_only')
	assert co.len == 1 && co[0].message == 'short names that differ only in case: Fiction, fiction'
	assert co[0].at.len == 2
}

fn test_content_key_writes_what_interpolation_does() {
	for parent in ['', 'P', 'SOME-PARENT'] {
		for h in [u64(0), 0xabcdef, 0xffffffffffffffff] {
			for before in [0, 1, 9, 10, 123456] {
				assert content_key(parent, h, before) == '${content_mark}${parent}\x1f${h:016x}\x1f${before}'
			}
		}
	}
}

fn test_key_part_is_what_split_gives() {
	for key in ['', 'a', 'a\x1fb', '\x1fb', 'a\x1f', 'a\x1fb\x1fc', '\x1f\x1f'] {
		for part in 0 .. 4 {
			assert key_part(key, part) == (key.split('\x1f')[part] or { '' }), '${key} ${part}'
		}
	}
	assert fold_cmp('Abc', 'aBC') == 0 && fold_cmp('a', 'B') < 0 && fold_cmp('b', 'A') > 0
}

fn test_an_ignored_element_is_no_difference_of_a_repetition() {
	pallet := fn (label string) string {
		return '<ITEMS><BOOK><SHORT-NAME>Dune</SHORT-NAME><PALLETS><PALLET>${label}<CONTENTS><ITEM>sand</ITEM></CONTENTS></PALLET></PALLETS></BOOK></ITEMS>'
	}
	m := lib_files('ignored', ['', pallet('')], ['', pallet('<LABEL>x</LABEL>')])
	p := default_policy()
	sc := compile_schemas(m, os.join_path(@VMODROOT, 'testdata', 'schemas'), policy: p)
	c := check(m, sc, skip_xml: true, skip_references: true, skip_multiplicity: true)!
	assert c.findings.any(it.kind == 'repeated_differs')
	d := check(m, sc,
		skip_xml:          true
		skip_references:   true
		skip_multiplicity: true
		ignore_elements:   [
			'LABEL',
		]
	)!
	assert !d.findings.any(it.layer == .merge)
	assert count_named(d, 'PALLET') == 1
}
