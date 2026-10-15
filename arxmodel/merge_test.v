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

fn test_rules_become_flatxml_rules() {
	rs := lib_schema_rules()
	f := rs.to_flat()
	// a wrapper is a single, merged child; its items keyed and merged when splittable
	w := flat_rule(f, 'LIBRARY', 'SHELVES')
	assert w.single && w.merge
	sh := flat_rule(f, 'SHELVES', 'SHELF')
	assert described(f, 'SHELVES', 'SHELF') == 'key=SHORT-NAME,VARIATION-POINT/SHORT-LABEL merge'
	assert sh.merge && !sh.single && sh.key_fn != none
	// a role of one value is a single, merged child
	sn := flat_rule(f, 'SHELF', 'SHORT-NAME')
	assert sn.single && sn.merge && sn.key_fn == none
	// a box has a key, but one item: single
	bx := flat_rule(f, 'SHELF', 'BOX')
	assert bx.single && bx.merge
	// a wrapper of item content: its content one child each, by the wrapper's rule
	m := flat_rule(f, 'MARKS', 'ROW')
	assert !m.single && m.key_fn == none && m.ordered
	// a key of a repeated element, or of no path, is computed
	assert described(f, 'LOANS', 'LOAN') == 'key=BORROWER-REF,CONTEXT-REF*,@UUID merge'
	crate := flat_rule(f, 'CRATES', 'CRATE')
	assert crate.key_fn != none
	assert f.rules.fold
}

fn lib_schema_rules() &RuleSet {
	s := xsd.load(mdata('schemas', 'LIB_1', 'LIB_1.xsd')) or { panic(err) }
	return read_rules(s)
}

fn test_pair_two_holders_disagree_on_is_settled_by_the_documents() {
	rs := lib_schema_rules()
	pairs := rs.conflicting_pairs()
	assert pairs == ['NOTES NOTE']
	// no document: a conflict nothing uses
	f0 := rs.to_flat()
	assert f0.settled.len == 0 && f0.conflicts.len == 0 && f0.unused.len == 1
	// only shelves' notes: the shelf's rule
	f1 := rs.to_flat(
		contexts: {
			'NOTES NOTE': {
				'SHELF': 2
			}
		}
	)
	assert f1.settled.len == 1 && f1.conflicts.len == 0
	r1 := flat_rule(f1, 'NOTES', 'NOTE')
	assert r1.ordered && r1.max == 3 && r1.key_fn == none
	// only books' notes: the book's rule, the note keyed by its own text
	f2 := rs.to_flat(
		contexts: {
			'NOTES NOTE': {
				'BOOK': 1
			}
		}
	)
	assert described(f2, 'NOTES', 'NOTE') == 'key=. merge'
	// both: a conflict
	f3 := rs.to_flat(
		contexts: {
			'NOTES NOTE': {
				'BOOK':  1
				'SHELF': 2
			}
		}
	)
	assert f3.conflicts.len == 1 && f3.conflicts[0].occurs == 3
	assert f3.conflicts[0].rules.len == 2
}

fn test_item_kinds_of_one_rule_are_one_flatxml_rule() {
	rs := lib_schema_rules()
	f := rs.to_flat()
	mut found := false
	for r in f.rules.rules {
		if r.parent == 'ITEMS' {
			assert r.children == ['BOOK', 'MAGAZINE']
			found = true
		}
	}
	assert found
}

fn test_spec_tells_own_text_from_one_key_for_all() {
	own := Spec{
		keyed: true
		key:   ['']
		all:   [false]
	}
	none_ := Spec{
		keyed: true
	}
	assert !own.same(none_)
	assert own.str() != none_.str()
}

fn test_unresolved_key_is_one_child_each() {
	rs := lib_schema_rules()
	f := rs.to_flat()
	b := flat_rule(f, 'BROKEN-KEYS', 'LOAN')
	assert b.key_fn == none && !b.single
	assert f.lost_keys == 1
}

fn test_flat_wrapper_content_most_per_item() {
	rs := lib_schema_rules()
	f := rs.to_flat()
	// MARKS holds any number of marks, each a ROW or a COLUMN
	assert flat_rule(f, 'MARKS', 'ROW').max == 0
}

fn test_absent_key_parts_read_as_empty() {
	read := key_reader(['SHORT-NAME', 'VARIATION-POINT/SHORT-LABEL', '@ID'], [false, false, false])
	a := flatxml.parse_string('<P><X/></P>') or { panic(err) }
	b := flatxml.parse_string('<P><SHORT-NAME>n</SHORT-NAME></P>') or { panic(err) }
	// every part absent: the empty key, which every such item shares
	assert read(a.root_node()) or { 'none' } == flatxml.key_sep + flatxml.key_sep
	assert read(b.root_node()) or { 'none' } == 'n' + flatxml.key_sep + flatxml.key_sep
	one := key_reader([], [])
	assert one(a.root_node()) or { 'none' } == ''
}

fn test_repeated_key_values_do_not_run_together() {
	read := key_reader(['CONTEXT-REF'], [true])
	a := flatxml.parse_string('<L><CONTEXT-REF>a b</CONTEXT-REF></L>') or { panic(err) }
	b := flatxml.parse_string('<L><CONTEXT-REF>a</CONTEXT-REF><CONTEXT-REF>b</CONTEXT-REF></L>') or {
		panic(err)
	}
	ka := read(a.root_node()) or { '' }
	kb := read(b.root_node()) or { '' }
	assert ka != kb
}

fn test_check_merges_and_reports_with_positions() {
	mut m := load([mdata('merge')])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, mdata('schemas'))
	mut c := check(m, sc)!
	assert c.governing == 'LIB_1.xsd'
	// NOTES/NOTE under both a shelf and a book: a conflict the documents cannot settle
	assert c.flat.conflicts.len == 1
	mut v := c.view
	// Fiction and fiction are one shelf (keys ignore case); Dune is one book
	shelf := v.root().child('SHELVES', '').child('SHELF', 'Fiction' + flatxml.key_sep)
	assert shelf.fragment_count() == 2
	dune := shelf.child('ITEMS', '').child('BOOK', 'Dune')
	assert dune.ok() && dune.fragment_count() == 2
	assert shelf.child('ITEMS', '').child('MAGAZINE', 'Analog').ok()
	// two loans: one borrower, different contexts
	loans := shelf.child('LOANS', '')
	assert loans.child_count() == 2
	// the one violation: Fiction and fiction differ as names; what lies on NOTES/NOTE is the
	// conflict's
	assert c.violations == 1
	for k, p in v.problems {
		d := v.describe(p)
		assert d.contains('x.arxml:') && d.contains('y.arxml:')
		if p.kind == .value_differs {
			assert p.what == 'SHORT-NAME' && !c.in_conflict[k]
		} else {
			assert c.in_conflict[k]
		}
	}
}
