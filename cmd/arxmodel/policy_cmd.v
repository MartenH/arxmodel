module main

import arxmodel
import os

// cmd_policy shows the policy (--policy, the specification's by default): every setting with
// the values it takes, its value and the specification item it concerns, then the severities;
// --diff NAME shows how another policy differs; --schema writes policy.schema.json (to -o FILE,
// else standard output).
fn cmd_policy(o Opts) {
	if o.schema {
		text := arxmodel.policy_schema_json()
		if o.out == '' || o.out == '-' {
			print(text)
		} else {
			os.write_file(o.out, text) or { trouble('${o.out}: ${err.msg()}') }
			println('wrote ${o.out}')
		}
		return
	}
	p := load_policy(o)
	if o.diff != '' {
		q := arxmodel.named_policy(o.diff) or {
			trouble(err.msg())
			return
		}
		lines := arxmodel.policy_diff(p, q)
		println('${p.source} -> ${q.source}: ${plural(lines.len, 'difference')}')
		for l in lines {
			println(l)
		}
		return
	}
	println('policy: ${p.source}')
	for st in arxmodel.policy_settings() {
		allowed := match st.kind {
			.choice { st.allowed.map('"${it}"').join(' | ') }
			.boolean { 'true | false' }
			.names { 'a list of attribute names' }
			.element { 'an element name' }
			.table { 'a table of "Class.role" = "role"' }
		}
		spec := if st.spec != '' { '  [${st.spec}]' } else { '' }
		println('[${st.table}] ${st.key} = ${st.value(p)}    (${allowed})${spec}')
	}
	mut keys := p.severities.keys()
	keys.sort()
	for k in keys {
		println('[severity] "${k}" = "${p.severities[k]}"')
	}
	for f in p.filters {
		println('[[filter]] ${f.number} = ${f.toml()}')
	}
}
