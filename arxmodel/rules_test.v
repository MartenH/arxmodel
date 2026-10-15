module arxmodel

import flatxml.xsd
import os

fn lib_rules() &RuleSet {
	s := xsd.load(os.join_path(@VMODROOT, 'testdata', 'schemas', 'LIB_1', 'LIB_1.xsd')) or {
		panic(err)
	}
	return read_rules(s)
}

fn rule_named(rs &RuleSet, name string) Rule {
	for r in rs.rules {
		if r.name == name {
			return r
		}
	}
	panic('no rule ${name}')
}

fn type_idx(rs &RuleSet, name string) u32 {
	return rs.types_of[name][0]
}

fn item_keys(r Rule, item string) []string {
	for it in r.items {
		if it.element == item {
			return it.key.map(it.str())
		}
	}
	panic('no item ${item} in ${r.name}')
}

fn test_wrapped_role_with_key() {
	rs := lib_rules()
	r := rule_named(rs, 'Library.shelf')
	assert r.class == 'Library' && r.role == 'shelf'
	assert r.element == 'SHELVES' && r.wrapper
	assert r.items.map(it.element) == ['SHELF']
	assert r.items[0].type_name == 'SHELF'
	assert r.splittable && !r.ordered
	assert r.max == unbounded && r.min == 0
	assert r.key_spec == ['shelf.shortName', 'shelf.variationPoint.shortLabel']
	assert item_keys(r, 'SHELF') == ['SHORT-NAME', 'VARIATION-POINT/SHORT-LABEL']
	assert r.problems.len == 0
}

fn test_lookup_by_parent_type_and_child_element() {
	rs := lib_rules()
	shelf := type_idx(rs, 'SHELF')
	assert rs.type_name(shelf) == 'SHELF'
	r := rs.rule_for(shelf, 'ITEMS') or { panic('no rule for ITEMS') }
	assert r.name == 'Shelf.item'
	// a role of a shared group is a role of every type that holds the group
	sn := rs.rule_for(type_idx(rs, 'BOOK'), 'SHORT-NAME') or { panic('no SHORT-NAME') }
	assert sn.name == 'Named.shortName' && sn.min == 1 && sn.max == 1
	assert rs.rule_for(shelf, 'NOPE') == none
}

fn test_several_item_kinds_each_keyed() {
	rs := lib_rules()
	r := rule_named(rs, 'Shelf.item')
	assert r.items.map(it.element) == ['BOOK', 'MAGAZINE']
	assert item_keys(r, 'BOOK') == ['SHORT-NAME']
	assert item_keys(r, 'MAGAZINE') == ['SHORT-NAME']
}

fn test_ordered_and_limited() {
	rs := lib_rules()
	r := rule_named(rs, 'Shelf.note')
	assert r.ordered && !r.splittable && !r.has_key()
	assert r.max == 3
	assert r.element == 'NOTES' && r.items.map(it.element) == ['NOTE']
}

fn test_role_wrapped_by_element_of_no_role() {
	rs := lib_rules()
	r := rule_named(rs, 'Shelf.label')
	assert r.element == 'LABELS' && r.wrapper
	assert r.items.map(it.element) == ['LABEL']
	// the role's own name is the item itself
	assert item_keys(r, 'LABEL') == ['.']
	assert (rs.rule_for(type_idx(rs, 'SHELF'), 'LABELS') or { panic('no LABELS') }).name == 'Shelf.label'
}

fn test_reference_named_by_its_class() {
	rs := lib_rules()
	r := rule_named(rs, 'Shelf.favourite')
	assert item_keys(r, 'BOOK-REF-CONDITIONAL') == ['BOOK-REF', 'VARIATION-POINT/SHORT-LABEL']
	b := rule_named(rs, 'Book')
	assert b.role == 'book' && b.class == '' && b.element == 'BOOK-REF'
}

fn test_attribute_and_repeated_key_parts() {
	rs := lib_rules()
	r := rule_named(rs, 'Shelf.loan')
	assert item_keys(r, 'LOAN') == ['BORROWER-REF', 'CONTEXT-REF*', '@UUID']
}

fn test_key_problems_are_reported() {
	rs := lib_rules()
	r := rule_named(rs, 'Shelf.broken')
	assert r.problems.map(it.kind) == ['key role not found', 'key role differs in case',
		'key through a multi-valued role']
	// a role spelled with another case is still applied
	assert item_keys(r, 'LOAN') == ['VARIATION-POINT/SHORT-LABEL']
	assert rs.census.problems['key role not found'] == 2 // and one in Shelf.mark
}

fn test_repeated_class_content_takes_the_schema_count() {
	rs := lib_rules()
	r := rule_named(rs, 'Paragraph.bold')
	assert r.max == unbounded
	assert rule_named(rs, 'Values.v').max == unbounded
	assert rs.census.notes["mixed content allows more than pureMM.maxOccurs; the schema's count is used"] == 2
}

fn test_census_accounts_for_every_annotation() {
	rs := lib_rules()
	c := rs.census
	assert c.appinfo == 51
	// counted by what the reader did, never by a list of the schema's vocabulary
	assert c.other['tag foo.bar'] == 1
	assert c.other['stereotype atpWeird'] == 1
	assert c.other['source elsewhere'] == 1
	assert c.other['tag atp.Status'] == 1
	assert c.other['stereotype atpIdentityContributor'] == 1
	assert c.checked['tag xml.roleWrapperElement'] == 4
	assert c.used['stereotype atpSplitable'] == 10
	assert c.used['stereotype instanceRef'] == 1
	assert c.used['tag atp.Splitkey'] == 10
	// a tag the reader uses, where it does not read it
	assert c.not_read['tag mmt.qualifiedName on group'] == 1
	assert c.not_read['tag pureMM.minOccurs on attribute'] == 2
	assert c.not_read['tag pureMM.maxOccurs on attribute'] == 2
	assert c.used['tag pureMM.maxOccurs'] == 33 // element roles; one of the 34 has none
	assert c.not_read['tag pureMM.maxOccurs on element'] == 1
	assert c.used['tag mmt.qualifiedName'] == 36 // 34 element roles and two attribute roles
	assert c.malformed == ['nonsense']
	assert c.notes['xml.roleWrapperElement agrees with the schema'] == 3
	assert c.problems['xml.roleWrapperElement disagrees with the schema'] == 1
}

fn test_wrapper_holding_item_content_without_item_elements() {
	rs := lib_rules()
	r := rule_named(rs, 'Shelf.mark')
	assert r.wrapper && r.flat && r.ordered
	assert r.element == 'MARKS'
	assert r.items.map(it.element) == ['ROW', 'COLUMN']
}

fn test_flat_wrapper_items_are_not_repeated_by_the_wrapper() {
	rs := lib_rules()
	assert rule_named(rs, 'Mark.row').max == 1
	assert rule_named(rs, 'Mark.column').max == 1
	assert rule_named(rs, 'Shelf.mark').max == unbounded
}

fn test_flat_wrapper_key_resolved_once() {
	rs := lib_rules()
	r := rule_named(rs, 'Shelf.mark')
	assert item_keys(r, 'ROW') == ['ROW']
	assert item_keys(r, 'COLUMN') == ['ROW']
	assert r.problems.len == 1
	assert r.problems[0].kind == 'key role not found'
	assert r.problems[0].msg.contains('for ROW, COLUMN')
}

fn test_wrapper_of_a_sequence_counts_every_item() {
	rs := lib_rules()
	r := rule_named(rs, 'Shelf.pair')
	assert r.wrapper && r.items.map(it.element) == ['LEFT', 'RIGHT']
	assert r.max == 2
}

fn test_declared_flat_wrapper_with_a_value_is_its_own_item() {
	rs := lib_rules()
	r := rule_named(rs, 'Shelf.motto')
	assert !r.flat && !r.wrapper
	assert r.items.map(it.element) == ['MOTTO']
	assert r.problems.map(it.kind) == ['xml.roleWrapperElement disagrees with the schema']
}

fn test_item_itself_keyed_by_its_single_valued_children() {
	rs := lib_rules()
	// text values in the order the type writes them; not an attribute (BARCODE), the
	// multi-valued, the splittable or another object; a reference to an instance by its own
	// children; a value behind an element of no role
	r := rule_named(rs, 'Shelf.copy')
	assert item_keys(r, 'COPY') == ['EDITION', 'YEAR', 'LOCATION-IREF/CONTEXT-REF',
		'LOCATION-IREF/TARGET-REF', 'CODES/CODE']
	assert r.problems.len == 0
	// a value is its own key
	assert item_keys(rule_named(rs, 'Shelf.label'), 'LABEL') == ['.']
}

fn test_item_itself_with_no_single_value() {
	rs := lib_rules()
	// one item: every fragment is it
	b := rule_named(rs, 'Shelf.box')
	assert item_keys(b, 'BOX') == []
	assert b.problems.len == 0
	assert b.notes == ['key of a single item with no single-valued children: every fragment is the one item']
	assert b.empty_keys == ['BOX']
	// several items that nothing tells apart
	c := rule_named(rs, 'Shelf.crate')
	assert item_keys(c, 'CRATE') == []
	assert c.problems.map(it.kind) == ['key item has no single-valued children']
}
