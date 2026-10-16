module arxmodel

import flatxml

// Values identified by a definition: an ECUC parameter or reference value is the value of the
// definition it names (and of its variation point's label), so two files, or two versions, giving
// it different values give one value that differs. A definition given more than once under one
// parent, in any document read, has several values (a multi-instance parameter or reference):
// those are a set, each value told apart by its content as well. Whether a definition takes
// several values is the definition's own multiplicity, which no schema states and the definition
// files are not always at hand for, so it is seen in the documents.

// IdentityRole is one role whose items are identified so: the element holding them, the items'
// element names, and the paths below an item of its definition and its label.
pub struct IdentityRole {
pub:
	parent     string
	items      []string
	definition string
	label      string
}

// ValueKeys keys the items of identity roles, by what was seen in the documents.
@[heap]
pub struct ValueKeys {
pub mut:
	roles []IdentityRole
	// `definition sep label` given more than once under one parent: a set
	multi map[string]bool
}

// role_of is the identity role an element is an item of, by its name and its parent's, each
// compared without its prefix as the schema's role names are written.
fn (vk &ValueKeys) role_of(n flatxml.Node) ?IdentityRole {
	p := n.parent()
	if !p.ok() {
		return none
	}
	name, pname := local_part(n.name()), local_part(p.name())
	for r in vk.roles {
		if r.parent == pname && name in r.items {
			return r
		}
	}
	return none
}

// ident is an item's definition and label, joined.
fn ident_of(n flatxml.Node, r IdentityRole) string {
	return text_at(n, r.definition) + flatxml.key_sep + text_at(n, r.label)
}

// observe records, in every document of the models, the definitions given more than once under
// one parent.
pub fn (mut vk ValueKeys) observe(models []&Model) {
	if vk.roles.len == 0 {
		return
	}
	for m in models {
		for d in m.set.docs {
			vk.observe_node(d.root_node())
		}
	}
}

fn (mut vk ValueKeys) observe_node(n flatxml.Node) {
	mut seen := map[string]bool{}
	for c in n.children() {
		if r := vk.role_of(c) {
			k := ident_of(c, r)
			if k in seen {
				vk.multi[k] = true
			}
			seen[k] = true
		}
		vk.observe_node(c)
	}
}

// key is an item's key: its definition and label; for a definition with several values, its
// content too. None for an element of no identity role, or with neither.
pub fn (vk &ValueKeys) key(n flatxml.Node) ?string {
	r := vk.role_of(n)?
	k := ident_of(n, r)
	if flatxml.empty_key(k) {
		return none
	}
	if k in vk.multi {
		return k + flatxml.key_sep + content_of(n, r)
	}
	return k
}

// content_of is what an item holds besides its definition and label: each element's path (of
// local names, so a prefix does not tell two values apart) and text, in order.
fn content_of(n flatxml.Node, r IdentityRole) string {
	skip := [r.definition.all_before('/'), r.label.all_before('/')]
	mut out := []string{}
	for c in n.children() {
		local := local_part(c.name())
		if local !in skip {
			leaf_texts(c, local, mut out)
		}
	}
	return out.join(flatxml.key_list_sep)
}

fn leaf_texts(n flatxml.Node, path string, mut out []string) {
	mut any := false
	for c in n.children() {
		any = true
		leaf_texts(c, '${path}/${local_part(c.name())}', mut out)
	}
	if !any {
		out << '${path}=${n.text().trim_space()}'
	}
}

// names_items_of reports whether a rule is one for the items of an identity role: under its
// parent, naming only its items.
fn (vk &ValueKeys) names_items_of(r flatxml.Rule) bool {
	tail := r.parent.all_after_last('/')
	for role in vk.roles {
		if role.parent == tail && r.children.len > 0 && r.children.all(it in role.items) {
			return true
		}
	}
	return false
}

// with_value_keys is a rule set whose rules for identity roles key their items by `vk`.
pub fn with_value_keys(rs flatxml.RuleSet, vk &ValueKeys) flatxml.RuleSet {
	if vk.roles.len == 0 {
		return rs
	}
	key_fn := fn [vk] (n flatxml.Node) ?string {
		return vk.key(n)
	}
	mut rules := []flatxml.Rule{cap: rs.rules.len}
	for r in rs.rules {
		if vk.names_items_of(r) {
			// the key function reads the same paths, and more
			rules << flatxml.Rule{
				...r
				key:    []
				key_fn: key_fn
			}
		} else {
			rules << r
		}
	}
	return flatxml.RuleSet{
		...rs
		rules: rules
	}
}

// value_keys is the value keys of a set of flat rules, seen in the models.
pub fn (f &Flat) value_keys(models []&Model) &ValueKeys {
	mut vk := &ValueKeys{
		roles: f.identity_roles
	}
	vk.observe(models)
	return vk
}
