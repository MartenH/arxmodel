module arxmodel

import flatxml
import toml

// default_policy_text is the committed policy.toml, built in.
const default_policy_text = $embed_file('../policy.toml').to_string()

// PolicyCache holds the built-in policy once it is read.
@[heap]
struct PolicyCache {
mut:
	read   bool
	policy Policy
}

// builtin_policy is read on first use, not at start: reading it is work no command needs twice.
const builtin_policy = &PolicyCache{}

// ItemItself is how an item named by the role itself is keyed when it has children.
pub enum ItemItself {
	single_values // its single-valued element children
}

// Policy is every merge choice that is arxmodel's rather than the schema's (policy.toml).
pub struct Policy {
pub mut:
	absent_keys              flatxml.Keyless = .empty
	fold                     bool            = true
	ignore_attrs             []string
	ignore_declarations      bool = true
	item_itself              ItemItself
	repeated_choice_as_mixed bool   = true
	package_element          string = 'AR-PACKAGE'
	// a finding's severity by `layer`, `layer.kind` or `layer.kind:what`; error where unset
	severities map[string]Severity
}

// default_policy is the built-in policy.toml.
pub fn default_policy() Policy {
	mut c := unsafe { builtin_policy }
	if !c.read {
		c.policy = parse_policy(default_policy_text) or { panic('the built-in policy.toml: ${err}') }
		c.read = true
	}
	return c.policy
}

// rule_settings are the settings a rule set is made by, `name value` each: a rules file is made
// by them and keeps them.
pub fn (p Policy) rule_settings() []string {
	return [
		'absent_keys ${if p.absent_keys == .empty { 'empty' } else { 'own' }}',
		'item_itself single_values',
		'governing newest_declared',
		'splittable schema',
		'repeated_choice_as_mixed ${if p.repeated_choice_as_mixed { 'yes' } else { 'no' }}',
	]
}

// merge_settings are the settings a merge applies, `name value` each.
pub fn (p Policy) merge_settings() []string {
	return [
		'key_case ${if p.fold { 'ignore' } else { 'exact' }}',
		'ignore_attrs ${p.ignore_attrs.join(' ')}'.trim_space(),
		'ignore_declarations ${if p.ignore_declarations { 'yes' } else { 'no' }}',
		'file_info_comment compare',
	]
}

// PolicySetting is one setting of a policy: its table, its key, and how its value is read.
struct PolicySetting {
	table string
	key   string
	read  fn (mut p Policy, name string, v toml.Any) ! = unsafe { nil }
}

// policy_settings are every setting a policy has, each required.
fn policy_settings() []PolicySetting {
	return [
		PolicySetting{'merge', 'absent_keys', read_absent_keys},
		PolicySetting{'merge', 'key_case', read_key_case},
		PolicySetting{'merge', 'ignore_attrs', read_ignore_attrs},
		PolicySetting{'merge', 'ignore_declarations', read_ignore_declarations},
		PolicySetting{'merge', 'item_itself', read_item_itself},
		PolicySetting{'merge', 'repeated_choice_as_mixed', read_repeated_choice},
		PolicySetting{'merge', 'file_info_comment', read_file_info_comment},
		PolicySetting{'schema', 'governing', read_governing},
		PolicySetting{'schema', 'splittable', read_splittable},
		PolicySetting{'references', 'package_element', read_package_element},
	]
}

fn read_absent_keys(mut p Policy, name string, v toml.Any) ! {
	p.absent_keys = if one_of(name, v, ['empty', 'own'])! == 'empty' { .empty } else { .own }
}

fn read_key_case(mut p Policy, name string, v toml.Any) ! {
	p.fold = one_of(name, v, ['ignore', 'exact'])! == 'ignore'
}

fn read_ignore_attrs(mut p Policy, name string, v toml.Any) ! {
	if v !is []toml.Any {
		return error('policy: `${name}` takes a list of attribute names, not ${show_value(v)}')
	}
	mut attrs := []string{}
	for a in v.array() {
		if a !is string || !xml_name(a.string()) {
			return error('policy: `${name}`: ${show_value(a)} is not an attribute name')
		}
		attrs << a.string()
	}
	// the names are written into a rules file: what flatxml's writer refuses is refused here
	flatxml.format_rules(flatxml.RuleSet{ ignore_attrs: attrs }) or {
		return error('policy: `${name}`: ${err.msg()}')
	}
	p.ignore_attrs = attrs
}

fn read_ignore_declarations(mut p Policy, name string, v toml.Any) ! {
	p.ignore_declarations = boolean(name, v)!
}

fn read_item_itself(mut p Policy, name string, v toml.Any) ! {
	one_of(name, v, ['single_values'])!
	p.item_itself = .single_values
}

fn read_repeated_choice(mut p Policy, name string, v toml.Any) ! {
	p.repeated_choice_as_mixed = boolean(name, v)!
}

fn read_file_info_comment(mut _ Policy, name string, v toml.Any) ! {
	one_of(name, v, ['compare'])!
}

fn read_governing(mut _ Policy, name string, v toml.Any) ! {
	one_of(name, v, ['newest_declared'])!
}

fn read_splittable(mut _ Policy, name string, v toml.Any) ! {
	one_of(name, v, ['schema'])!
}

fn read_package_element(mut p Policy, name string, v toml.Any) ! {
	if v !is string || !xml_name(v.string()) {
		return error('policy: `${name}` takes an element name, not ${show_value(v)}')
	}
	p.package_element = v.string()
}

// parse_policy reads a policy, a TOML document: a table for each table of policy_settings, every
// setting given with a value this build supports, and a severity table. Anything else is refused,
// named.
pub fn parse_policy(text string) !Policy {
	doc := toml.parse_text(text) or {
		if hint := unquoted_severity_key(text) {
			return error('policy: severity key `${hint}` has a dot: quote it, "${hint}" = ...')
		}
		return error('policy: ${err.msg()}')
	}
	top := doc.to_any().as_map()
	settings := policy_settings()
	mut tables := ['severity']
	for st in settings {
		if st.table !in tables {
			tables << st.table
		}
	}
	for key, v in top {
		if v is map[string]toml.Any {
			if key !in tables {
				return error('policy: unknown table [${key}]')
			}
			continue
		}
		for st in settings {
			if st.key == key {
				return error('policy: `${key}` is outside its table; it belongs in [${st.table}]')
			}
		}
		return error('policy: unknown setting `${key}`, outside any table')
	}
	mut p := Policy{}
	for table in tables {
		if table == 'severity' {
			continue
		}
		t := top[table] or { return error('policy: no table [${table}]') }
		m := t.as_map()
		for k, _ in m {
			if !settings.any(it.table == table && it.key == k) {
				return error('policy: unknown setting `${table}.${k}`')
			}
		}
	}
	for st in settings {
		v := top[st.table] or { toml.Any(toml.Null{}) }.as_map()[st.key] or {
			return error('policy: `${st.table}.${st.key}` is not set')
		}
		st.read(mut p, '${st.table}.${st.key}', v)!
	}
	if sev := top['severity'] {
		for key, v in sev.as_map() {
			if v is map[string]toml.Any {
				return error('policy: severity `${key}` is a table; quote a key with a dot, as "${key}.kind"')
			}
			value := one_of('severity "${key}"', v, ['error', 'warning', 'ignore'])!
			check_severity_key(key)!
			p.severities[key] = match value {
				'error' { Severity.error }
				'warning' { Severity.warning }
				else { Severity.ignore }
			}
		}
	}
	return p
}

// check_severity_key refuses a severity key that names no layer, no kind of its layer, or an
// element or attribute that is not an XML name (`@` before an attribute's).
fn check_severity_key(key string) ! {
	layer := key.all_before('.').all_before(':')
	kinds := known_kinds[layer] or { return error('policy: severity `${key}`: no layer `${layer}`') }
	if !key.contains('.') {
		if key.contains(':') {
			return error('policy: severity `${key}`: an element or attribute needs a kind')
		}
		return
	}
	kind := key.all_after('.').all_before(':')
	if kind !in kinds {
		return error('policy: severity `${key}`: no kind `${kind}` in layer ${layer}')
	}
	if key.contains(':') {
		what := key.all_after(':')
		name := if what.starts_with('@') { what[1..] } else { what }
		if !xml_name(name) {
			return error('policy: severity `${key}`: `${what}` is not an element name or an @attribute name')
		}
	}
}

// unquoted_severity_key finds, when a policy does not parse, a dotted key under [severity] that is
// not quoted: TOML reads `merge.too_many` as a table, which fails where `merge` has a value.
fn unquoted_severity_key(text string) ?string {
	mut in_severity := false
	for raw in text.split_into_lines() {
		line := raw.all_before('#').trim_space()
		if line.starts_with('[') {
			in_severity = line == '[severity]'
			continue
		}
		if !in_severity || !line.contains('=') {
			continue
		}
		key := line.all_before('=').trim_space()
		if !key.starts_with('"') && !key.starts_with("'") && key.contains('.') {
			return key
		}
	}
	return none
}

// xml_name reports whether s is an XML name (ASCII letters, digits, `_`, `-`, `.`, `:`, and any
// character beyond ASCII; not starting with a digit, `-` or `.`).
fn xml_name(s string) bool {
	if s == '' {
		return false
	}
	for i, c in s {
		if c >= 0x80 || c.is_letter() || c == `_` || c == `:` {
			continue
		}
		if i > 0 && (c.is_digit() || c == `-` || c == `.`) {
			continue
		}
		return false
	}
	return true
}

// toml_setting is a `name value` setting, as a rules file records it, in the policy file's
// spelling: `[merge] repeated_choice_as_mixed = false`.
pub fn toml_setting(line string) string {
	name := line.all_before(' ')
	value := if line.contains(' ') { line.all_after(' ') } else { '' }
	mut table := ''
	for st in policy_settings() {
		if st.key == name {
			table = st.table
		}
	}
	if table == '' {
		return line
	}
	shown := match name {
		'ignore_declarations', 'repeated_choice_as_mixed' {
			if value == 'yes' {
				'true'
			} else if value == 'no' {
				'false'
			} else {
				'"${value}"'
			}
		}
		'ignore_attrs' {
			'[' + value.fields().map('"' + it + '"').join(', ') + ']'
		}
		else {
			'"${value}"'
		}
	}
	return '[${table}] ${name} = ${shown}'
}

// one_of is a string setting's value, refused unless it is one of allowed.
fn one_of(name string, v toml.Any, allowed []string) !string {
	if v !is string || v.string() !in allowed {
		return error('policy: `${name}` takes one of ${allowed.map('"' + it + '"').join(', ')}, not ${show_value(v)}')
	}
	return v.string()
}

// boolean is a boolean setting's value, refused unless it is true or false.
fn boolean(name string, v toml.Any) !bool {
	if v !is bool {
		return error('policy: `${name}` takes true or false, not ${show_value(v)}')
	}
	return v.bool()
}

fn show_value(v toml.Any) string {
	return if v is string { '"${v}"' } else { v.to_toml() }
}
