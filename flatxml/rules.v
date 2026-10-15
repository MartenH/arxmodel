module flatxml

// KeyFn computes a child's key where paths cannot say it; none means the child has no key.
pub type KeyFn = fn (n Node) ?string

// key_sep joins the parts of a key made of several paths. XML text cannot hold it, so two keys
// of different parts never read alike.
pub const key_sep = '\x1f'

// Rule says how the children of one aggregation are told apart and put together: the children
// named `children` of an element named `parent`. A rule is of one of three kinds:
//
// - keyed (`key` or `key_fn` given): children are identified by their key, which is unique in
//   their scope, the nearest ancestor that is not a single child; with `merge`, the children
//   of one key are one child, else the second is a collision;
// - single: one child of each name, identified by its name; with `merge`, every occurrence is
//   that child, else the second is a collision;
// - each: every occurrence is a child of its own.
//
// A child no rule names is of the kind each.
pub struct Rule {
pub:
	parent   string   // the parent's element name; '' or '*' for any parent
	children []string // the child element names the aggregation holds; empty (or '*') for any
	// key is the paths below the child whose texts make its key: `NAME`, `ITEM/ID`; an attribute
	// is `@id` (the child's own) or `ITEM/@id`. A missing part reads as ''; a child missing every
	// part has no key.
	key    []string
	key_fn ?KeyFn // the key computed by the caller, in place of key
	single bool   // the aggregation holds one child
	merge  bool   // occurrences of one key (or of a single child) are one child
	// ordered and max are for keyed and each aggregations; a single one holds one child a name
	ordered bool // the order means something: every child from one document, kept as written
	max     int  // the most children the aggregation may hold; 0 for no limit
}

// RuleSet is the rules of a merge. A child is matched by the rule for its parent's name and its
// own, then its parent's name and any child, then any parent and its own name, then any parent
// and any child. Children of different aggregations are ordered as their rules are listed, and
// children no rule names come after them, as written.
pub struct RuleSet {
pub:
	rules        []Rule
	fold         bool     // keys compared ignoring ASCII case
	ignore_attrs []string // attributes whose values may differ between contributions to a node
}

enum RuleKind as u8 {
	each
	single
	keyed
}

struct KeyPart {
	path Path
	attr u32 // the attribute's name id; no_name for the element's text
}

struct CRule {
	kind    RuleKind
	parts   []KeyPart
	key_fn  ?KeyFn
	merge   bool
	ordered bool
	max     int
}

// CompiledRules is a rule set with its names as ids of one table.
struct CompiledRules {
	rules  []CRule
	fold   bool
	ignore []u32 // ids of the attributes not compared
mut:
	pairs    map[u64]u32 // (parent id, child id) -> rule; id 0 stands for any
	resolved map[u64]u32 // the same, with the fallbacks applied, as met
}

fn pair_key(parent u32, child u32) u64 {
	return (u64(parent) << 32) | child
}

fn any_name(s string) bool {
	return s == '' || s == '*'
}

// compile checks the rules and turns their names into ids of t. Two rules for one pair of
// names, a rule both keyed and single, or one with both key paths and a key function, are
// refused.
fn (rs &RuleSet) compile(t &Names) !CompiledRules {
	mut out := CompiledRules{
		fold: rs.fold
	}
	mut seen := map[string]int{}
	mut rules := []CRule{cap: rs.rules.len}
	for k, r in rs.rules {
		keyed := r.key.len > 0 || r.key_fn != none
		if r.key.len > 0 && r.key_fn != none {
			return error('rule ${k + 1} (${r.parent} ${r.children}): key paths and a key function')
		}
		if keyed && r.single {
			return error('rule ${k + 1} (${r.parent} ${r.children}): keyed and single')
		}
		if r.max < 0 {
			return error('rule ${k + 1} (${r.parent} ${r.children}): max ${r.max}')
		}
		mut parts := []KeyPart{}
		for p in r.key {
			at := p.index_u8(`@`)
			if at >= 0 && (p[at..].contains('/') || at + 1 == p.len) {
				return error('rule ${k + 1}: key path `${p}`: an attribute ends a path')
			}
			path := if at < 0 { p } else { p[..at] }
			// an attribute no document has gets an id no attribute has
			attr := if at < 0 { no_name } else { t.id(p[at + 1..]) or { no_name - 1 } }
			parts << KeyPart{t.path(path), attr}
		}
		mut kind := RuleKind.each
		if keyed {
			kind = .keyed
		} else if r.single {
			kind = .single
		}
		rules << CRule{
			kind:    kind
			parts:   parts
			key_fn:  r.key_fn
			merge:   r.merge
			ordered: r.ordered
			max:     r.max
		}
		parent := if any_name(r.parent) { '*' } else { r.parent }
		kids := if r.children.len == 0 || (r.children.len == 1 && any_name(r.children[0])) {
			['*']
		} else {
			r.children
		}
		for c in kids {
			if any_name(c) && kids.len > 1 {
				return error('rule ${k + 1}: `*` among other child names')
			}
			pair := '${parent} ${c}'
			if prev := seen[pair] {
				return error('rules ${prev + 1} and ${k + 1} both name ${pair}')
			}
			seen[pair] = k
			pid := if parent == '*' { u32(0) } else { t.id(parent) or { continue } }
			cid := if c == '*' { u32(0) } else { t.id(c) or { continue } }
			out.pairs[pair_key(pid, cid)] = u32(k)
		}
	}
	mut ignore := []u32{}
	for a in rs.ignore_attrs {
		ignore << t.id(a) or { continue }
	}
	return CompiledRules{
		...out
		rules:  rules
		ignore: ignore
	}
}

// resolve is the rule for a child named child of an element named parent; no_rule for none.
fn (mut cr CompiledRules) resolve(parent u32, child u32) u32 {
	k := pair_key(parent, child)
	if r := cr.resolved[k] {
		return r
	}
	r := cr.pairs[k] or {
		cr.pairs[pair_key(parent, 0)] or {
			cr.pairs[pair_key(0, child)] or { cr.pairs[u64(0)] or { no_rule } }
		}
	}
	cr.resolved[k] = r
	return r
}

// key is the child's key under a keyed rule; none when it has none.
fn (cr &CRule) key(c Node) ?string {
	if f := cr.key_fn {
		return f(c)
	}
	if cr.parts.len == 1 {
		return cr.parts[0].read(c)
	}
	mut parts := []string{len: cr.parts.len}
	mut any := false
	for k, p in cr.parts {
		if s := p.read(c) {
			parts[k] = s
			any = true
		}
	}
	return if any { parts.join(key_sep) } else { none }
}

fn (p &KeyPart) read(c Node) ?string {
	n := if p.path.names.len == 0 { c } else { c.find(p.path) }
	if !n.ok() {
		return none
	}
	if p.attr == no_name {
		return n.text()
	}
	return n.doc.attr_by_id(n.i, p.attr)
}

// parse_rules reads rules from text, one per line:
//
//   # a comment; blank lines are ignored
//   !fold                   keys are compared ignoring ASCII case
//   !ignore <attr>...       attributes whose values may differ between contributions
//   <parent> <child>[,<child>...] [key=<path>[,<path>...]] [single] [merge] [ordered] [max=<n>]
//
// `*` stands for any parent or any child. A setting starts with `!`, which no element name can,
// so every name can have a rule. Rules are listed in the order their children are written.
pub fn parse_rules(text string) !RuleSet {
	mut rules := []Rule{}
	mut fold := false
	mut ignore := []string{}
	for n, raw in text.split_into_lines() {
		line := raw.all_before('#').trim_space()
		if line == '' {
			continue
		}
		words := line.fields()
		if words[0].starts_with('!') {
			match words[0] {
				'!fold' {
					if words.len > 1 {
						return error('line ${n + 1}: `!fold` takes nothing')
					}
					fold = true
				}
				'!ignore' {
					ignore << words[1..]
				}
				else {
					return error('line ${n + 1}: unknown setting `${words[0]}`')
				}
			}
			continue
		}
		if words.len < 2 {
			return error('line ${n + 1}: expected `<parent> <children> [options]`')
		}
		mut key := []string{}
		mut single, mut merge, mut ordered := false, false, false
		mut max := 0
		for w in words[2..] {
			if w.starts_with('key=') {
				key = w[4..].split(',').filter(it != '')
				if key.len == 0 {
					return error('line ${n + 1}: an empty key')
				}
			} else if w.starts_with('max=') {
				max = w[4..].int()
				if max <= 0 || '${max}' != w[4..] {
					return error('line ${n + 1}: `${w}` is not a count')
				}
			} else {
				match w {
					'single' { single = true }
					'merge' { merge = true }
					'ordered' { ordered = true }
					else { return error('line ${n + 1}: unknown option `${w}`') }
				}
			}
		}
		rules << Rule{
			parent:   words[0]
			children: words[1].split(',').filter(it != '')
			key:      key
			single:   single
			merge:    merge
			ordered:  ordered
			max:      max
		}
	}
	return RuleSet{
		rules:        rules
		fold:         fold
		ignore_attrs: ignore
	}
}
