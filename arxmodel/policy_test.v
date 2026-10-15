module arxmodel

import flatxml.xsd
import os

fn pdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

fn policy_with(name string, value string) Policy {
	mut lines := []string{}
	for line in default_policy_text.split_into_lines() {
		lines << if line.starts_with(name + ' ') { '${name} ${value}' } else { line }
	}
	return parse_policy(lines.join('\n')) or { panic(err) }
}

fn lib_rules_by(p Policy) &RuleSet {
	s := xsd.load(pdata('schemas', 'LIB_1', 'LIB_1.xsd')) or { panic(err) }
	return read_rules_with(s, p)
}

fn test_the_built_in_policy() {
	p := default_policy()
	assert p.absent_keys == .empty && p.fold && p.ignore_attrs == ['UUID']
	assert p.ignore_declarations && p.item_itself == .single_values && p.repeated_choice_as_mixed
	// read once
	assert default_policy().text == default_policy_text
}

fn test_a_policy_must_say_everything_it_knows() {
	if _ := parse_policy('absent_keys empty') {
		assert false
	}
	if _ := parse_policy(default_policy_text.replace('absent_keys empty', 'absent_keys maybe')) {
		assert false
	}
	if _ := parse_policy(default_policy_text + '\nwhatever yes') {
		assert false
	}
	if _ := parse_policy(default_policy_text.replace('governing newest_declared', 'governing oldest')) {
		assert false
	}
}

fn test_policy_absent_keys_reaches_the_rules() {
	rs := lib_rules_by(default_policy())
	own := policy_with('absent_keys', 'own')
	assert rs.to_flat(keyless: own.absent_keys).rules.rules.filter(it.key.len > 0).all(it.keyless == .own)
	assert rs.to_flat().rules.rules.filter(it.key.len > 0).all(it.keyless == .empty)
}

fn test_policy_takes_only_what_is_implemented() {
	if _ := parse_policy(default_policy_text.replace('item_itself single_values', 'item_itself whole')) {
		assert false
	}
}

fn test_policy_absent_keys_changes_the_merge() {
	mut m := load([pdata('absent')])!
	defer {
		m.free()
	}
	// a LOAN with no key part in each of two files
	empty := check(m, compile_schemas(m, pdata('schemas')))!
	own := check(m, compile_schemas(m, pdata('schemas'), policy: policy_with('absent_keys', 'own')))!
	// one empty key: one loan, of two elements, and nothing to report
	assert empty.view.problems.len == 0
	assert empty.view.len() == own.view.len() - 1
	// each its own: two loans, each missing its key
	assert own.view.problems.map('${it.kind}') == ['missing_key', 'missing_key']
}

fn test_policy_repeated_choice_as_mixed() {
	no := lib_rules_by(policy_with('repeated_choice_as_mixed', 'no'))
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
	st := default_policy().settings()
	fold, ignore := st.apply(m, CheckOptions{})
	assert fold && 'UUID' in ignore && 'xsi:schemaLocation' in ignore
	exact, _ := policy_with('key_case', 'exact').settings().apply(m, CheckOptions{})
	assert !exact
	// the command line overrides the policy
	cs, _ := st.apply(m, case_sensitive: true)
	assert !cs
	_, compared := st.apply(m, compare_attrs: ['UUID'])
	assert 'UUID' !in compared
	_, decl := policy_with('ignore_declarations', 'no').settings().apply(m, CheckOptions{})
	assert 'xsi:schemaLocation' !in decl
	// and it shows in the merge: Fiction and fiction are two shelves when case counts
	folded := check(m, compile_schemas(m, pdata('schemas')))!
	apart := check(m, compile_schemas(m, pdata('schemas'), policy: policy_with('key_case', 'exact')))!
	assert folded.view.len() < apart.view.len()
}
