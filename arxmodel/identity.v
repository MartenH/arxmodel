module arxmodel

import flatxml
import toml

// identity_text is the committed identity.toml, built in: the identity rules used when no schema
// is given.
const identity_text = $embed_file('../identity.toml').to_string()

// Identity is how elements are named without a schema (identity.toml).
pub struct Identity {
pub:
	name          []string // the paths whose texts name an element: the first must be present
	by_definition []string // element name patterns named by their definition
	definition    string   // the child holding the definition
}

// builtin_identity is identity.toml, read.
pub fn builtin_identity() Identity {
	return parse_identity(identity_text) or { panic('the built-in identity.toml: ${err}') }
}

// parse_identity reads identity rules: an [identity] table with name, by_definition and
// definition, nothing else.
pub fn parse_identity(text string) !Identity {
	doc := toml.parse_text(text) or { return error('identity: ${err.msg()}') }
	top := doc.to_any().as_map()
	for k, _ in top {
		if k != 'identity' {
			return error('identity: unknown table [${k}]')
		}
	}
	t := (top['identity'] or { return error('identity: no table [identity]') }).as_map()
	for k, _ in t {
		if k !in ['name', 'by_definition', 'definition'] {
			return error('identity: unknown setting `identity.${k}`')
		}
	}
	name := strings_of(t, 'name')!
	if name.len == 0 {
		return error('identity: `identity.name` names no path')
	}
	def := t['definition'] or { return error('identity: `identity.definition` is not set') }
	if def !is string || def.string() == '' {
		return error('identity: `identity.definition` takes a path')
	}
	return Identity{
		name:          name
		by_definition: strings_of(t, 'by_definition')!
		definition:    def.string()
	}
}

fn strings_of(t map[string]toml.Any, key string) ![]string {
	v := t[key] or { return error('identity: `identity.${key}` is not set') }
	if v !is []toml.Any {
		return error('identity: `identity.${key}` takes a list of strings')
	}
	mut out := []string{}
	for x in v.array() {
		if x !is string || x.string() == '' {
			return error('identity: `identity.${key}` takes a list of strings')
		}
		out << x.string()
	}
	return out
}

// glob reports whether name matches a pattern whose one `*` stands for any part of it.
fn glob(pattern string, name string) bool {
	if !pattern.contains('*') {
		return pattern == name
	}
	head := pattern.all_before('*')
	tail := pattern.all_after('*')
	return name.len >= head.len + tail.len && name.starts_with(head) && name.ends_with(tail)
}

// Identified is identity rules as applied to some documents: what was seen in them decides which
// element names are lists, and which definitions take several values.
@[heap]
pub struct Identified {
pub:
	id Identity
pub mut:
	lists map[string]bool // element names some document holds as a list of named elements
	// `definition sep label` of values given more than once under one parent
	multi map[string]bool
}

// value_role is how a value named by its definition is read.
fn (id &Identity) value_role() IdentityRole {
	return IdentityRole{
		definition: id.definition
		label:      if id.name.len > 1 { id.name[1] } else { '' }
	}
}

// is_value reports whether an element is a value named by its definition: an element of a
// by_definition name with no short name (a container, which has one, is named by both).
fn (id &Identity) is_value(n flatxml.Node) bool {
	return id.by_definition.any(glob(it, n.name())) && text_at(n, id.name[0]) == ''
}

// named is the name of an element by these rules, or none: its short name (and the further
// parts); for an element named by its definition, the definition and the label (and a
// container's short name); for a definition of several values, the value's content too.
fn (x &Identified) named(n flatxml.Node) ?string {
	id := x.id
	if id.by_definition.any(glob(it, n.name())) {
		r := id.value_role()
		k := ident_of(n, r)
		s := text_at(n, id.name[0])
		if flatxml.empty_key(k) && s == '' {
			return none
		}
		if s == '' && k in x.multi {
			return k + flatxml.key_sep + content_of(n, r)
		}
		return s + flatxml.key_sep + k
	}
	first := text_at(n, id.name[0])
	if first == '' {
		return none
	}
	mut parts := [first]
	for p in id.name[1..] {
		parts << text_at(n, p)
	}
	return parts.join(flatxml.key_sep)
}

// observe records, in every document of the models, the names held as lists and the definitions
// given more than once under one parent.
pub fn (mut x Identified) observe(models []&Model) {
	for m in models {
		for d in m.set.docs {
			x.observe_node(d.root_node())
		}
	}
}

fn (mut x Identified) observe_node(n flatxml.Node) {
	mut seen := map[string]bool{}
	mut any := false
	mut all_named := true
	r := x.id.value_role()
	for c in n.children() {
		any = true
		if x.id.is_value(c) {
			k := ident_of(c, r)
			if k in seen {
				x.multi[k] = true
			}
			seen[k] = true
		} else if text_at(c, x.id.name[0]) == '' && !x.id.by_definition.any(glob(it, c.name())) {
			all_named = false
		}
		x.observe_node(c)
	}
	if any && all_named && n.name() !in x.lists {
		x.lists[n.name()] = true
	}
}

// text_at is the text of the element at a path of child names below n ('' where there is none),
// read child by child.
fn text_at(n flatxml.Node, path string) string {
	if !path.contains('/') {
		c := n.child(path)
		return if c.ok() { c.text().trim_space() } else { '' }
	}
	mut cur := n
	for name in path.split('/') {
		cur = cur.child(name)
		if !cur.ok() {
			return ''
		}
	}
	return cur.text().trim_space()
}

// key is an element's key by these rules: its name; for a list (an element name some document
// holds as a list of named elements, so an emptied one is still the list), its element name
// (list_key), the one key of its namesakes; else none (matched by place).
pub fn (x &Identified) key(n flatxml.Node) ?string {
	if k := x.named(n) {
		return k
	}
	return if n.name() in x.lists { list_key(n.name()) } else { none }
}

// list_key is the key of a list: its element name, after a separator no text can hold, so it is
// never a name's key, and lists of different names under one parent stay apart.
pub fn list_key(name string) string {
	return flatxml.key_sep + name
}

// identity_flat is the merge rules of identity rules, as applied to the models: every child of
// every parent keyed as `key` says, merged by its key, an unkeyed one each its own.
pub fn identity_flat(id Identity, models []&Model) Flat {
	mut x := &Identified{
		id: id
	}
	x.observe(models)
	key_fn := fn [x] (n flatxml.Node) ?string {
		return x.key(n)
	}
	return Flat{
		rules:             flatxml.RuleSet{
			rules: [
				flatxml.Rule{
					parent:  '*'
					key_fn:  key_fn
					keyless: .own
					merge:   true
				},
			]
		}
		described:         ['built-in identity']
		unkeyed_by_design: true
	}
}
