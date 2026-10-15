module arxmodel

import flatxml

// default_policy_text is the committed policy.txt, built in.
const default_policy_text = $embed_file('../policy.txt').to_string()

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

// Policy is every merge choice that is arxmodel's rather than the schema's (policy.txt).
pub struct Policy {
pub mut:
	absent_keys              flatxml.Keyless = .empty
	fold                     bool            = true
	ignore_attrs             []string
	ignore_declarations      bool = true
	item_itself              ItemItself
	repeated_choice_as_mixed bool = true
	package_element          string = 'AR-PACKAGE'
	// a finding's severity by `layer`, `layer.kind` or `layer.kind:what`; error where unset
	severities map[string]Severity
	text       string // the text it was read from
}

// default_policy is the built-in policy.txt.
pub fn default_policy() Policy {
	mut c := unsafe { builtin_policy }
	if !c.read {
		c.policy = parse_policy(default_policy_text) or { panic('the built-in policy.txt: ${err}') }
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

// parse_policy reads a policy: one `name value...` a line, `#` comments. Every setting must be
// given, once, with a value this build supports.
pub fn parse_policy(text string) !Policy {
	mut p := Policy{
		text: text
	}
	mut seen := map[string]bool{}
	for n, raw in text.split_into_lines() {
		line := raw.all_before('#').trim_space()
		if line == '' {
			continue
		}
		words := line.fields()
		name := words[0]
		args := words[1..]
		if name == 'severity' {
			if args.len != 2 || args[1] !in ['error', 'warning', 'ignore'] {
				return error('policy line ${n + 1}: `severity <layer>[.<kind>[:<what>]] error|warning|ignore`')
			}
			layer := args[0].all_before('.')
			kinds := known_kinds[layer] or {
				return error('policy line ${n + 1}: no layer `${layer}`')
			}
			if args[0].contains('.') {
				kind := args[0].all_after('.').all_before(':')
				if kind !in kinds {
					return error('policy line ${n + 1}: no kind `${kind}` in layer ${layer}')
				}
				if args[0].contains(':') && args[0].all_after(':') == '' {
					return error('policy line ${n + 1}: an empty element or attribute after `:`')
				}
			}
			if args[0] in p.severities {
				return error('policy line ${n + 1}: the severity of `${args[0]}` given twice')
			}
			p.severities[args[0]] = match args[1] {
				'error' { Severity.error }
				'warning' { Severity.warning }
				else { Severity.ignore }
			}
			continue
		}
		if name in seen {
			return error('policy line ${n + 1}: `${name}` given twice')
		}
		seen[name] = true
		one := fn [n, name, args] (allowed []string) !string {
			if args.len != 1 || args[0] !in allowed {
				return error('policy line ${n + 1}: `${name}` takes one of ${allowed.join(', ')}')
			}
			return args[0]
		}
		match name {
			'absent_keys' {
				p.absent_keys = if one(['empty', 'own'])! == 'empty' { .empty } else { .own }
			}
			'key_case' {
				p.fold = one(['ignore', 'exact'])! == 'ignore'
			}
			'ignore_attrs' {
				for a in args {
					if a.contains(',') || a.starts_with('!') {
						return error('policy line ${n + 1}: `${a}` is not an attribute name')
					}
				}
				p.ignore_attrs = args.clone()
			}
			'ignore_declarations' {
				p.ignore_declarations = one(['yes', 'no'])! == 'yes'
			}
			'item_itself' {
				one(['single_values'])!
			}
			'governing' {
				one(['newest_declared'])!
			}
			'splittable' {
				one(['schema'])!
			}
			'repeated_choice_as_mixed' {
				p.repeated_choice_as_mixed = one(['yes', 'no'])! == 'yes'
			}
			'file_info_comment' {
				one(['compare'])!
			}
			'package_element' {
				if args.len != 1 {
					return error('policy line ${n + 1}: `${name}` takes one element name')
				}
				p.package_element = args[0]
			}
			else {
				return error('policy line ${n + 1}: unknown setting `${name}`')
			}
		}
	}
	for need in ['absent_keys', 'key_case', 'ignore_attrs', 'ignore_declarations', 'item_itself',
		'governing', 'splittable', 'repeated_choice_as_mixed', 'file_info_comment', 'package_element'] {
		if need !in seen {
			return error('policy: `${need}` is not set')
		}
	}
	return p
}
