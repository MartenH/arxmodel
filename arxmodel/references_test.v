module arxmodel

import os

fn fdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

fn ref_check(opts CheckOptions) !Checked {
	mut m := load([fdata('refs')])!
	return check(m, compile_schemas(m, fdata('schemas')), opts)
}

// the reference findings as `kind line`, in the order they are reported
fn ref_kinds_at(c Checked) []string {
	return c.findings.filter(it.layer == .reference).map('${it.kind} ${it.at[0].all_after_last('r.arxml:').all_before_last(':')}')
}

fn test_paths_are_indexed_from_short_names() {
	mut m := load([fdata('merge')])!
	defer {
		m.free()
	}
	c := check(m, compile_schemas(m, fdata('schemas')))!
	ix := c.index
	assert ix.by_path.keys().sorted() == ['/fiction', '/fiction/analog', '/fiction/dune']
	dune := c.view.node(ix.holders('/Fiction/Dune')[0])
	assert dune.name() == 'BOOK' && dune.fragment_count() == 2
	assert ix.path_of[dune.i] == '/Fiction/Dune'
	// a finding's path: the referrable element, then the elements below it
	assert c.findings.any(it.path == '/Fiction#NOTES')
}

fn test_referrable_from_the_schema() {
	mut m := load([fdata('refs')])!
	sc := compile_schemas(m, fdata('schemas'))
	mut ty := new_typing(sc.uses[0].schema)
	// the class whose own content declares SHORT-NAME
	assert ty.referrable.len == 1
	s := sc.uses[0].schema
	assert s.names[s.groups[ty.referrable.keys()[0]].name.local] == 'NAMED'
	c := check(m, sc)!
	// BOOK's PICK-REF has the reference's name but is plain text: not a reference
	assert c.refs.checked == 12
	for k, p in c.index.path_of {
		assert ty.referrable_type(c.index.typ[k]), p
	}
	// a node below a keyed item: the item with its key, after the referrable element's path
	mut borrower := ''
	for i in 0 .. c.view.len() {
		n := c.view.node(u32(i))
		if n.name() == 'BORROWER-REF' {
			borrower = merged_path(n, c.index)
		}
	}
	assert borrower.starts_with('/Fiction#LOANS/LOAN[Ann') && borrower.ends_with(']/BORROWER-REF'), borrower
}

fn test_references_resolved_by_path_and_kind() {
	c := ref_check()!
	assert ref_kinds_at(c) == ['duplicate_path 24', 'duplicate_path 27', 'wrong_kind 12',
		'wrong_kind 13', 'unresolved 14', 'relative 15', 'relative 16', 'wrong_kind 18',
		'case_mismatch 19', 'empty 20', 'external 21']
	refs := c.findings.filter(it.layer == .reference)
	assert refs.filter(it.kind != 'duplicate_path').all(it.path == '/Fiction#PICK-REF')
	sev := refs.map('${it.kind} ${it.severity}')
	for want in ['unresolved error', 'wrong_kind error', 'empty error', 'duplicate_path error',
		'external warning', 'case_mismatch warning', 'relative warning'] {
		assert want in sev
	}
	// line 17: DEST names a class BOOK is a kind of; line 22: one of the two holders of
	// /Poetry/Odes is the MAGAZINE asked for
	assert c.refs.by_top == {
		'unresolved /Fiction': 1
		'external /Elsewhere': 1
	}
	// the layer can be skipped
	d := ref_check(skip_references: true)!
	assert !d.findings.any(it.layer == .reference) && d.refs.checked == 0
}

fn test_a_path_held_twice_keeps_both_in_document_order() {
	c := ref_check(skip_references: true)!
	ix := c.index
	assert ix.dup == ['/Poetry', '/Poetry/Odes']
	assert ix.holders('/Poetry/Odes').map(c.view.node(it).name()) == ['BOOK', 'MAGAZINE']
	assert ix.holders('/POETRY/odes').len == 2
}

fn test_paths_compared_as_the_merge_compares_keys() {
	// keys as written: the reference spelled in another case finds nothing (and nothing of it)
	c := ref_check(case_sensitive: true)!
	assert 'external 19' in ref_kinds_at(c)
	assert c.index.holders('/FICTION/DUNE').len == 0
}

fn test_external_by_the_nearest_existing_ancestor() {
	// with SHELF the package element, a book missing from a shelf is a definition not loaded
	mut m := load([fdata('refs')])!
	p := parse_policy(default_policy_text.replace('package_element AR-PACKAGE', 'package_element SHELF'))!
	c := check(m, compile_schemas(m, fdata('schemas'), policy: p))!
	assert 'external 14' in ref_kinds_at(c)
	// files loaded only to resolve against: /Elsewhere/Atlas is there, and nothing of them is
	// reported
	e := ref_check(refs_from: [fdata('refs_extra')])!
	assert 'external 21' !in ref_kinds_at(e) && e.refs_from_files == 1
	assert !e.findings.any(it.at.any(it.contains('refs_extra')))
}

fn test_a_policy_line_sets_a_reference_severity() {
	p := parse_policy(default_policy_text.replace('severity reference.relative warning',
		'severity reference.relative ignore'))!
	assert p.severity(.reference, 'relative', 'X') == .ignore
	if _ := parse_policy(default_policy_text + '\nseverity reference.dangling error') {
		assert false
	}
}
