module arxmodel

import os
import toml
import x.json2

fn test_the_committed_schema_is_the_generated_one() {
	committed := os.read_file(os.join_path(@VMODROOT, 'policy.schema.json'))!
	assert committed == policy_schema_json(), 'policy.schema.json is stale: run `arxmodel policy --schema -o policy.schema.json`'
}

// conforms checks a policy file against the schema: every table and setting it gives is one the
// schema has, of the schema's type, a choice among its values; every required one is there.
fn conforms(text string, schema map[string]json2.Any) ! {
	doc := toml.parse_text(text)!
	tables := schema['properties']!.as_map()
	for t in schema['required']!.as_array() {
		doc.to_any().as_map()[t.str()] or { return error('no table [${t.str()}]') }
	}
	for table, v in doc.to_any().as_map() {
		ts := (tables[table] or { return error('a table the schema has not: [${table}]') }).as_map()
		if table == 'filter' {
			items := ts['items']!.as_map()
			props := items['properties']!.as_map()
			for k, f in v.array() {
				for req in items['required']!.as_array() {
					f.as_map()[req.str()] or { return error('filter ${k + 1}: no ${req.str()}') }
				}
				for key, value in f.as_map() {
					ps := (props[key] or { return error('filter ${k + 1}: a field the schema has not: ${key}') }).as_map()
					if e := ps['enum'] {
						if value.string() !in e.as_array().map(it.str()) {
							return error('filter ${k + 1}: ${key}: ${value.string()} is not one of the enum')
						}
					}
				}
			}
			continue
		}
		if table == 'severity' {
			allowed := ts['additionalProperties']!.as_map()['enum']!.as_array().map(it.str())
			for k, sv in v.as_map() {
				if sv.string() !in allowed {
					return error('severity "${k}": ${sv.string()}')
				}
			}
			continue
		}
		props := ts['properties']!.as_map()
		for req in ts['required']!.as_array() {
			v.as_map()[req.str()] or { return error('${table}.${req.str()} missing') }
		}
		for key, value in v.as_map() {
			ps := (props[key] or { return error('a setting the schema has not: ${table}.${key}') }).as_map()
			typ := ps['type']!.str()
			ok := match typ {
				'string' { value is string }
				'boolean' { value is bool }
				'array' { value is []toml.Any }
				'object' { value is map[string]toml.Any }
				else { false }
			}
			if !ok {
				return error('${table}.${key} is not of type ${typ}')
			}
			if e := ps['enum'] {
				if value.string() !in e.as_array().map(it.str()) {
					return error('${table}.${key}: ${value.string()} is not one of the enum')
				}
			}
		}
	}
}

fn test_both_policy_files_conform_to_the_schema() {
	schema := (json2.decode[json2.Any](policy_schema_json())!).as_map()
	for name in ['policy.toml', 'automat.policy.toml'] {
		text := os.read_file(os.join_path(@VMODROOT, name))!
		assert text.starts_with('#:schema ./policy.schema.json\n'), name
		conforms(text, schema) or { assert false, '${name}: ${err.msg()}' }
	}
	// with filters, as policy.toml's commented example has them
	with_filters := default_policy_text + '\n[[filter]]\nmatch = "reference.relative"\nbase = "Trace"\nseverity = "ignore"\nreason = "traced"\n'
	parse_policy(with_filters)!
	conforms(with_filters, schema)!
	if _ := conforms(with_filters.replace('severity = "ignore"\nreason', 'severity = "never"\nreason'),
		schema)
	{
		assert false
	}
	// and the check refuses what does not conform
	bad := default_policy_text.replace('key_case = "exact"', 'key_case = "loose"')
	if _ := conforms(bad, schema) {
		assert false
	}
	// every setting is in the schema, with its default and its specification item
	merge := schema['properties']!.as_map()['merge']!.as_map()['properties']!.as_map()
	ki := merge['item_itself']!.as_map()
	assert ki['default']!.str() == 'copy' && ki['description']!.str().contains('TPS_GST_00417')
	assert policy_settings().filter(it.table == 'merge').len == merge.len
}

fn test_the_profiles_differ_where_the_specification_and_automat_do() {
	d := policy_diff(default_policy(), automat_policy())
	assert d.map(it.all_before(':')) == ['[merge] absent_keys', '[merge] key_case',
		'[merge] item_itself', '[merge] primitive_values', '[merge] repeated_content',
		'[merge] abstract_items', '[merge] file_info_comment']
	assert policy_diff(default_policy(), default_policy()).len == 0
}
