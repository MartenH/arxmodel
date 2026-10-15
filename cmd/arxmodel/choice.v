module main

import arxmodel
import os

// Chosen is the rules a command reads by, as resolve_rules decided: the built-in identity rules,
// a rules file, or a schema's.
struct Chosen {
mut:
	builtin  bool
	flat     arxmodel.Flat
	st       arxmodel.Settings
	name     string // the governing schema, or the schema a rules file was made from
	pv       arxmodel.Provenance
	sc       arxmodel.Schemas // the model's schemas: compiled for a schema, declared otherwise
	typing   &arxmodel.Typing = unsafe { nil }
	warnings []string
}

// choose reads the rules for models (versions of one model; their first is the one checked):
// the one place the choice is made. A schema is that of the newest release any of them declares.
fn choose(o Opts, models []&arxmodel.Model, policy arxmodel.Policy) !Chosen {
	if o.builtin {
		return Chosen{
			builtin: true
			flat:    arxmodel.identity_flat(arxmodel.builtin_identity(), models)
			st:      policy.settings()
			name:    'built-in identity rules'
			sc:      arxmodel.declare_schemas(models[0])
		}
	}
	if o.rules_file != '' {
		text := os.read_file(o.rules_file) or { return error('${o.rules_file}: ${err.msg()}') }
		flat, pv, st := arxmodel.parse_rules_file(text) or {
			return error('${o.rules_file}: ${err.msg()}')
		}
		sc := arxmodel.declare_schemas(models[0])
		warnings := arxmodel.rules_file_check(sc, pv, st, policy) or {
			return error('${o.rules_file}: ${err.msg()}')
		}
		return Chosen{
			flat:     flat
			st:       st
			name:     pv.schema
			pv:       pv
			sc:       sc
			warnings: warnings
		}
	}
	pick := arxmodel.newest_declaring(models)
	sc := arxmodel.compile_schemas(models[pick], o.schema_dir, policy: policy)
	flat, name := arxmodel.governing_flat(sc)!
	gov := arxmodel.governing_use(sc)!
	return Chosen{
		flat:   flat
		st:     policy.settings()
		name:   name
		sc:     sc
		typing: arxmodel.new_typing(gov.schema)
	}
}

// check_by checks a model by the rules chosen for it (the model they were chosen for): every
// layer with a schema, the merge and references otherwise.
fn check_by(ch &Chosen, m &arxmodel.Model, policy arxmodel.Policy, opts arxmodel.CheckOptions) !arxmodel.Checked {
	if ch.typing != unsafe { nil } {
		return arxmodel.check(m, ch.sc, opts)
	}
	return arxmodel.check_with(m, ch.flat, ch.name, ch.st, policy, opts)
}

// ruling is the chosen rules as a ruling for comparing versions.
fn (ch &Chosen) ruling(models []&arxmodel.Model, opts arxmodel.CheckOptions) arxmodel.Ruling {
	mut r := arxmodel.new_ruling(ch.flat, ch.name, ch.st, ch.typing, models, opts)
	r.builtin = ch.builtin
	return r
}
