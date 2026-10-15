module arxmodel

import flatxml.xsd
import os

fn pdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

// policy_text_with is the built-in policy with one setting's value replaced, written as TOML.
fn policy_text_with(name string, value string) string {
	mut lines := []string{}
	for line in automat_policy_text.split_into_lines() {
		lines << if line.starts_with(name + ' = ') { '${name} = ${value}' } else { line }
	}
	return lines.join('\n')
}

fn policy_with(name string, value string) Policy {
	return parse_policy(policy_text_with(name, value)) or { panic(err) }
}

fn lib_rules_by(p Policy) &RuleSet {
	s := xsd.load(pdata('schemas', 'LIB_1', 'LIB_1.xsd')) or { panic(err) }
	return read_rules_with(s, p)
}

fn test_the_built_in_policies() {
	// the default: the specification's merge
	p := default_policy()
	assert p.absent_keys == .own && !p.fold && p.ignore_attrs == ['UUID']
	assert p.ignore_declarations && p.item_itself == .copy && p.primitive_values == .copy
	assert p.repeated_content == .identical && p.abstract_items == .@union && p.ignore_structured
	assert p.repeated_choice_as_mixed && p.package_element == 'AR-PACKAGE'
	// automat's
	a := automat_policy()
	assert a.absent_keys == .empty && a.fold && a.item_itself == .single_values
	assert a.primitive_values == .merge_identical && a.repeated_content == .copy
	assert a.abstract_items == .per_kind && !a.ignore_structured
	// both identify ECUC values by their definition, and say the same severities
	assert p.item_identity == a.item_identity && p.severities == a.severities
	// by name or path
	assert named_policy('automat')!.fold && !named_policy('spec')!.fold
	assert named_policy('')!.source.starts_with('built-in')
	if _ := named_policy('/nonexistent/policy.toml') {
		assert false
	}
}

// with_severity is the built-in policy with keys added to its [severity] table, wherever the
// table is.
fn with_severity(keys string) string {
	return automat_policy_text.replace('\n[severity]\n', '\n[severity]\n${keys}\n')
}

// refused asserts that a policy is refused with a message containing says.
fn refused(text string, says string) {
	parse_policy(text) or {
		assert err.msg().contains(says), err.msg()
		return
	}
	assert false, 'accepted, expected: ${says}'
}

fn test_a_policy_must_say_everything_it_knows() {
	refused('[merge]\nabsent_keys = "empty"', 'no table [schema]')
	refused(automat_policy_text.replace('key_case = "ignore"', ''), '`merge.key_case` is not set')
	refused('[severity]\nmerge = "error"', 'no table [merge]')
	refused(automat_policy_text.replace('package_element = "AR-PACKAGE"', ''),
		'`references.package_element` is not set')
	refused(policy_text_with('absent_keys', '"maybe"'), '`merge.absent_keys` takes one of "own", "empty", not "maybe"')
	refused(policy_text_with('governing', '"oldest"'), '`schema.governing` takes one of "newest_declared", not "oldest"')
	refused(policy_text_with('item_itself', '"whole"'), '`merge.item_itself` takes one of "copy", "single_values", not "whole"')
	// typed: a boolean is a boolean, a list a list
	refused(policy_text_with('ignore_declarations', '"yes"'), '`merge.ignore_declarations` takes true or false, not "yes"')
	refused(policy_text_with('ignore_attrs', '"UUID"'), '`merge.ignore_attrs` takes a list of attribute names, not "UUID"')
	// unknown tables and keys, by name; a setting above its table, told where it belongs
	refused(automat_policy_text.replace('[schema]', '[schema]\nwhatever = true'), 'unknown setting `schema.whatever`')
	refused(automat_policy_text + '\n[extra]\na = 1', 'unknown table [extra]')
	refused('absent_keys = "empty"\n' + automat_policy_text, '`absent_keys` is outside its table; it belongs in [merge]')
	refused('whatever = 1\n' + automat_policy_text, 'unknown setting `whatever`, outside any table')
	refused(automat_policy_text.replace('key_case = "ignore"', 'key_case = "ignore"\nkey_case = "exact"'),
		'"key_case" is already initialized')
}

fn test_names_in_a_policy_are_names() {
	// an attribute is what a rules file can carry and an attribute can be called
	refused(policy_text_with('ignore_attrs', '["UUID,T"]'), '`merge.ignore_attrs`: "UUID,T" is not an attribute name')
	for bad in ['A B', 'A\\tB', 'A#B', '', '1A'] {
		refused(policy_text_with('ignore_attrs', '["${bad}"]'), 'is not an attribute name')
	}
	refused(policy_text_with('ignore_attrs', '[1]'), '`merge.ignore_attrs`: 1 is not an attribute name')
	assert policy_with('ignore_attrs', '["UUID", "xsi:type", "T-1"]').ignore_attrs == [
		'UUID',
		'xsi:type',
		'T-1',
	]
	refused(policy_text_with('package_element', '"AR PACKAGE"'), '`references.package_element` takes an element name, not "AR PACKAGE"')
	// a severity key: an element, or @ and an attribute, after the kind
	refused(with_severity('"merge.value_differs:SHORT NAME" = "error"'), '`SHORT NAME` is not an element name or an @attribute name')
	refused(with_severity('"merge.value_differs:@" = "error"'), '`@` is not an element name')
	refused(with_severity('"merge.value_differs:" = "error"'), '`` is not an element name')
	refused(with_severity('"merge:X" = "error"'), 'an element or attribute needs a kind')
	refused(with_severity('"nolayer" = "error"'), 'no layer `nolayer`')
	refused(with_severity('"merge.colision" = "error"'), 'no kind `colision` in layer merge')
	refused(with_severity('"multiplicity" = "maybe"'), 'takes one of "error", "warning", "ignore", not "maybe"')
	refused(with_severity('"merge" = "error"'), '"merge" is already initialized')
	p := parse_policy(with_severity('"merge.value_differs:@DEST" = "warning"'))!
	assert p.severity(.merge, 'value_differs', '@DEST') == .warning
}

fn test_a_dotted_severity_key_is_told_to_be_quoted() {
	// TOML reads it as a table: refused where the layer has a value, and where it has none
	refused(with_severity('merge.too_many = "ignore"'), 'severity key `merge.too_many` has a dot: quote it, "merge.too_many" = ...')
	refused(with_severity('multiplicity.too_many = "ignore"'), 'severity `multiplicity` is a table; quote a key with a dot')
}

fn test_settings_are_named_as_the_policy_file_spells_them() {
	assert toml_setting('repeated_choice_as_mixed no') == '[merge] repeated_choice_as_mixed = false'
	assert toml_setting('absent_keys own') == '[merge] absent_keys = "own"'
	assert toml_setting('ignore_attrs UUID T') == '[merge] ignore_attrs = ["UUID", "T"]'
	assert toml_setting('governing newest_declared') == '[schema] governing = "newest_declared"'
}

fn test_policy_absent_keys_reaches_the_rules() {
	rs := lib_rules_by(automat_policy())
	own := policy_with('absent_keys', '"own"')
	assert rs.to_flat(keyless: own.absent_keys).rules.rules.filter(it.key.len > 0).all(it.keyless == .own)
	assert rs.to_flat(keyless: .empty).rules.rules.filter(it.key.len > 0).all(it.keyless == .empty)
}

fn test_policy_takes_only_what_is_implemented() {
	if _ := parse_policy(policy_text_with('item_itself', '"whole"')) {
		assert false
	}
}

fn test_policy_absent_keys_changes_the_merge() {
	mut m := load([pdata('absent')])!
	defer {
		m.free()
	}
	// a LOAN with no key part in each of two files
	empty := check(m, compile_schemas(m, pdata('schemas'), policy: automat_policy()))!
	own := check(m, compile_schemas(m, pdata('schemas'),
		policy: policy_with('absent_keys', '"own"')
	))!
	// one empty key: one loan, of two elements, and nothing to report
	assert empty.view.problems.len == 0
	assert empty.view.len() == own.view.len() - 1
	// each its own: two loans, each missing its key
	assert own.view.problems.map('${it.kind}') == ['missing_key', 'missing_key']
}

fn test_policy_repeated_choice_as_mixed() {
	no := lib_rules_by(policy_with('repeated_choice_as_mixed', 'false'))
	yes := lib_rules_by(default_policy())
	for r in no.rules {
		if r.name == 'Values.v' {
			assert r.max == 1
		}
	}
	for r in yes.rules {
		if r.name == 'Values.v' {
			assert r.max == unbounded
		}
	}
}

fn test_policy_settings_and_their_overrides() {
	mut m := load([pdata('merge')])!
	defer {
		m.free()
	}
	st := automat_policy().settings()
	fold, ignore := st.apply(m, CheckOptions{})
	assert fold && 'UUID' in ignore && 'xsi:schemaLocation' in ignore
	exact, _ := policy_with('key_case', '"exact"').settings().apply(m, CheckOptions{})
	assert !exact
	// the command line overrides the policy
	cs, _ := st.apply(m, case_sensitive: true)
	assert !cs
	_, compared := st.apply(m, compare_attrs: ['UUID'])
	assert 'UUID' !in compared
	_, decl := policy_with('ignore_declarations', 'false').settings().apply(m, CheckOptions{})
	assert 'xsi:schemaLocation' !in decl
	// and it shows in the merge: Fiction and fiction are two shelves when case counts
	folded := check(m, compile_schemas(m, pdata('schemas'), policy: automat_policy()))!
	apart := check(m, compile_schemas(m, pdata('schemas'),
		policy: policy_with('key_case', '"exact"')
	))!
	assert folded.view.len() < apart.view.len()
	// and keys that differ only in case are said ([constr_2508])
	assert !folded.findings.any(it.kind == 'case_only')
	assert apart.findings.any(it.kind == 'case_only' && it.path == '#LIBRARY/SHELVES'
		&& it.message.contains('Fiction') && it.message.contains('fiction'))
}

fn test_item_identity_is_a_table_of_roles() {
	p := default_policy()
	assert p.item_identity == {
		'EcucContainerValue.parameterValue': 'definition'
		'EcucContainerValue.referenceValue': 'definition'
	}
	assert toml_setting('item_identity A.b=c D.e=f') == '[merge] item_identity = { "A.b" = "c", "D.e" = "f" }'
	refused(policy_text_with('item_identity', '"definition"'), '`merge.item_identity` takes a table of "Class.role" = "role", not "definition"')
	refused(policy_text_with('item_identity', '{ "parameterValue" = "definition" }'), '`merge.item_identity`: "parameterValue" is not a role, Class.role')
	refused(policy_text_with('item_identity', '{ "A.b" = 1 }'), '`merge.item_identity`: "A.b" takes a role name, not 1')
}
