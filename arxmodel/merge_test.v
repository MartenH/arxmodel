module arxmodel

import flatxml
import flatxml.xsd
import os

fn mdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

fn flat_rule(f Flat, parent string, child string) flatxml.Rule {
	return f.rules.rules[flat_index(f, parent, child)]
}

fn flat_index(f Flat, parent string, child string) int {
	for k, r in f.rules.rules {
		if r.parent == parent && child in r.children {
			return k
		}
	}
	panic('no rule ${parent} ${child}')
}

fn described(f Flat, parent string, child string) string {
	return f.described[flat_index(f, parent, child)]
}

fn rule_at(f Flat, parent string, child string) flatxml.Rule {
	return f.rules.rules[flat_index(f, parent, child)]
}

fn test_rules_become_flatxml_rules() {
	rs := lib_schema_rules()
	f := rs.to_flat()
	// a wrapper is a single, merged child; its items keyed and merged when splittable, an item
	// with no key part being the one with the empty key
	w := flat_rule(f, 'LIBRARY', 'SHELVES')
	assert w.single && w.merge
	sh := flat_rule(f, 'SHELVES', 'SHELF')
	assert sh.key == ['SHORT-NAME', 'VARIATION-POINT/SHORT-LABEL'] && sh.merge && !sh.single
	assert sh.keyless == .empty
	// a role of one value is a single, merged child
	sn := flat_rule(f, 'SHELF', 'SHORT-NAME')
	assert sn.single && sn.merge && sn.key.len == 0
	// a box has a key, but one item: single
	bx := flat_rule(f, 'SHELF', 'BOX')
	assert bx.single && bx.merge
	// items nothing tells apart have one key: merged where the role is splittable, a collision
	// where it is not
	cr := flat_rule(f, 'CRATES', 'CRATE')
	assert cr.single && cr.merge
	pa := flat_rule(f, 'PALLETS', 'PALLET')
	assert pa.single && !pa.merge
	// a wrapper of item content: its content one child each, by the wrapper's rule
	m := flat_rule(f, 'MARKS', 'ROW')
	assert !m.single && m.key.len == 0 && m.ordered
	// a key part whose element repeats reads every occurrence; an attribute part
	assert flat_rule(f, 'LOANS', 'LOAN').key == ['BORROWER-REF', 'CONTEXT-REF+', '@UUID']
	// the item's own text
	assert flat_rule(f, 'LABELS', 'LABEL').key == ['']
	// no key computed by the caller
	assert f.rules.rules.all(it.key_fn == none)
}

fn lib_schema_rules() &RuleSet {
	s := xsd.load(mdata('schemas', 'LIB_1', 'LIB_1.xsd')) or { panic(err) }
	return read_rules(s)
}

fn test_each_holder_its_own_rule_by_parent_path() {
	rs := lib_schema_rules()
	f := rs.to_flat()
	assert f.scoped == ['ITEMS MAGAZINE', 'NOTES NOTE', 'TAG-SET TAG']
	assert f.conflicts.len == 0
	// a wrapper's items, by the holder above the wrapper
	shelf := rule_at(f, 'NOTES', 'NOTE')
	assert shelf.ordered && shelf.max == 3 && shelf.key.len == 0
	book := rule_at(f, 'BOOK/NOTES', 'NOTE')
	assert book.key == [''] && book.merge && !book.ordered
	// a role written in its holder, by what holds an element of the holder's type; only the
	// holder whose rule differs from the first gets a path
	assert rule_at(f, 'TAG-SET', 'TAG').ordered
	assert rule_at(f, 'BOOK/TAG-SET', 'TAG').key == ['']
	assert !f.rules.rules.any(it.parent == 'SHELF/TAG-SET')
}

fn test_a_scoped_role_keeps_its_item_kinds_together_and_its_place() {
	rs := lib_schema_rules()
	f := rs.to_flat()
	// only MAGAZINE is given different rules, but the book's whole role is scoped, so ordered and
	// the most hold across its item kinds
	k := flat_index(f, 'BOOK/ITEMS', 'MAGAZINE')
	r := f.rules.rules[k]
	assert r.children == ['MAGAZINE', 'LEAFLET']
	assert r.ordered && r.max == 4
	// listed beside its unscoped counterpart, so the aggregations keep the schema's order
	bare := flat_index(f, 'ITEMS', 'MAGAZINE')
	assert k == bare + 1
	assert flat_index(f, 'BOOK/TAG-SET', 'TAG') == flat_index(f, 'TAG-SET', 'TAG') + 1
}

fn test_a_holder_no_path_names_is_a_conflict() {
	s := xsd.load(mdata('schemas', 'ROOTS_1', 'ROOTS_1.xsd')) or { panic(err) }
	rs := read_rules(s)
	f := rs.to_flat()
	// the global ROOT's ITEM differs from the first (a ROOT inside PARENT), and nothing is
	// above the global one
	assert f.scoped == ['ROOT ITEM']
	assert f.conflicts.len == 1 && f.unused().len == 1
	assert f.conflicts[0].parent == '/ROOT' && f.conflicts[0].child == 'ITEM'
	assert f.conflicts[0].rules.len == 2
}

fn test_flat_wrapper_content_is_scoped_by_its_holders() {
	rs := lib_schema_rules()
	c := rs.candidates()
	k := c.by_pair['MARKS ROW'][0]
	assert c.list[k].above == ['SHELF']
}

fn test_item_kinds_of_one_rule_are_one_flatxml_rule() {
	rs := lib_schema_rules()
	f := rs.to_flat()
	mut found := false
	for r in f.rules.rules {
		if r.parent == 'ITEMS' && 'BOOK' in r.children {
			assert r.children == ['BOOK', 'MAGAZINE']
			found = true
		}
	}
	assert found
}

fn test_spec_tells_own_text_from_another_key() {
	own := Spec{
		keyed: true
		key:   ['']
	}
	name := Spec{
		keyed: true
		key:   ['SHORT-NAME']
	}
	assert !own.same(name)
	assert own.str() == 'key=.'
}

fn test_unresolved_key_is_one_child_each() {
	rs := lib_schema_rules()
	f := rs.to_flat()
	b := flat_rule(f, 'BROKEN-KEYS', 'LOAN')
	assert b.key.len == 0 && !b.single
	assert f.lost_keys == 1
}

fn test_flat_wrapper_content_most_per_item() {
	rs := lib_schema_rules()
	f := rs.to_flat()
	// MARKS holds any number of marks, each a ROW or a COLUMN
	assert flat_rule(f, 'MARKS', 'ROW').max == 0
}

fn test_check_merges_and_reports_with_positions() {
	mut m := load([mdata('merge')])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, mdata('schemas'))
	mut c := check(m, sc)!
	assert c.governing == 'LIB_1.xsd'
	assert c.flat.conflicts.len == 0
	mut v := c.view
	// Fiction and fiction are one shelf (keys ignore case); Dune is one book
	shelf := v.root().child('SHELVES', '').child('SHELF', 'Fiction' + flatxml.key_sep)
	assert shelf.fragment_count() == 2
	dune := shelf.child('ITEMS', '').child('BOOK', 'Dune')
	assert dune.ok() && dune.fragment_count() == 2
	assert shelf.child('ITEMS', '').child('MAGAZINE', 'Analog').ok()
	// the book's notes by their text: signed in both files, worn in one
	notes := dune.child('NOTES', '')
	assert notes.child_count() == 2
	assert notes.child('NOTE', 'signed').fragment_count() == 2
	// two loans: one borrower, different contexts
	assert shelf.child('LOANS', '').child_count() == 2
	// the shelf's ordered notes in two files, and Fiction and fiction differ as names
	assert c.violations == 2
	mut kinds := v.problems.map('${it.kind}')
	kinds.sort()
	assert kinds == ['ordered_split', 'value_differs']
	for p in v.problems {
		d := v.describe(p)
		assert d.contains('x.arxml:') && d.contains('y.arxml:')
	}
}
