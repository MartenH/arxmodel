module arxmodel

import flatxml
import hash.fnv1a

// The checks the specification's merge asks for that flatxml's merge does not make: short names
// that differ only in case ([constr_2508]), and a non-splittable role repeated in several
// fragments that is not repeated identically ([constr_2524], [TPS_GST_00447]).

// content_mark starts a content key: a separator no text can hold, so a content key is never a
// name's, and paths show such an item by its place rather than by its key.
pub const content_mark = '\x1d'

// ContentHashes is a hash of each element's content, computed once per element, bottom up: its
// name, its attributes (sorted; those that may differ left out), its own text runs and its
// children's hashes. Only elements of repeated roles, and what is below them, are hashed.
@[heap]
pub struct ContentHashes {
	ignore []string
	nm     Naming // how the merge names the documents' elements
mut:
	// the identities (expanded names) of attributes any document spells by an ignored name, so
	// one ignored is ignored however another document spells it, as the merge ignores it
	ignored map[string]bool
	doc_of map[voidptr]int   // a document -> its number here
	hashes [][]u64           // per document number, per node: the hash, 0 until computed
	keys   [][]string        // per document number, per node: its repeat key, '' until made
	names  map[voidptr][]u64 // per name table: each name's hash, 0 until computed
}

pub fn new_content_hashes(ignore []string, nm Naming) &ContentHashes {
	return &ContentHashes{
		ignore: ignore.clone()
		nm:     nm
	}
}

// observe_ignored records, in every document of the models, the identity of each attribute
// spelled by an ignored name: what the merge ignores in every contribution.
pub fn (mut ch ContentHashes) observe_ignored(models []&Model) {
	if ch.ignore.len == 0 {
		return
	}
	for m in models {
		for d in m.set.docs {
			for a in 0 .. d.attr_tag.len {
				if d.attr_name(u32(a)) in ch.ignore {
					ch.ignored[d.tab.name(d.attr_id(u32(a)))] = true
				}
			}
		}
	}
}

fn mix(h u64, x u64) u64 {
	return (h ^ x) * u64(0x100000001b3)
}

fn (mut ch ContentHashes) slot(d &flatxml.Doc) int {
	if k := ch.doc_of[voidptr(d)] {
		return k
	}
	k := ch.hashes.len
	ch.doc_of[voidptr(d)] = k
	ch.hashes << []u64{len: d.tag.len}
	ch.keys << []string{}
	return k
}

// hash is the content hash of element n.
pub fn (mut ch ContentHashes) hash(n flatxml.Node) u64 {
	return ch.hash_at(ch.slot(n.doc), n.doc, n.i)
}

fn (mut ch ContentHashes) hash_at(k int, d &flatxml.Doc, i u32) u64 {
	if ch.hashes[k][i] != 0 {
		return ch.hashes[k][i]
	}
	mut h := mix(u64(0xcbf29ce484222325), ch.name_hash(d, i))
	// attributes, sorted by name
	lo, hi := d.attr_range(i)
	if hi > lo {
		mut attrs := []string{}
		for a := lo; a < hi; a++ {
			name := d.attr_name(a)
			id := d.tab.name(d.attr_id(a))
			if name !in ch.ignore && id !in ch.ignore && id !in ch.ignored && !d.is_ns_decl(a) {
				// by its identity (an expanded name in a namespace), as the merge compares it
				attrs << '${id}=${d.attr_value(a)}'
			}
		}
		attrs.sort()
		for a in attrs {
			h = mix(h, fnv1a.sum64_string(a))
		}
	}
	// own text, run by run in its slot among the children (indentation alone is no text), and
	// the children
	if d.text_len[i] != 0 {
		h = mix_text(h, 0, d, i)
	}
	mut slot := u64(0)
	mut c := d.first_child(i)
	for c != flatxml.no_node {
		if d.is_text(c) {
			h = mix_text(h, slot, d, c)
		} else if d.is_element(c) {
			slot++
			h = mix(h, ch.hash_at(k, d, c))
		}
		c = d.next_sibling(c)
	}
	if h == 0 {
		h = 1
	}
	ch.hashes[k][i] = h
	return h
}

// name_hash is the hash of a node's name as the merge names it, once per name of a table.
fn (mut ch ContentHashes) name_hash(d &flatxml.Doc, i u32) u64 {
	t := voidptr(d.tab)
	tag := ch.nm.tag(d, i)
	mut hs := ch.names[t] or { []u64{} }
	if tag < hs.len && hs[tag] != 0 {
		return hs[tag]
	}
	if tag >= hs.len {
		hs = []u64{len: int(tag) * 2 + 64}
		old := ch.names[t] or { []u64{} }
		for j, x in old {
			hs[j] = x
		}
	}
	h := fnv1a.sum64_string(d.tab.name(tag))
	hs[tag] = h
	ch.names[t] = hs
	return h
}

// mix_text mixes a text node's (or an element's own) text into h, in its slot: text that is only
// white space (indentation) is none.
fn mix_text(h u64, slot u64, d &flatxml.Doc, i u32) u64 {
	raw := d.text_raw(i)
	mut blank := true
	for b in raw {
		if b != ` ` && b != `\n` && b != `\t` && b != `\r` {
			blank = false
			break
		}
	}
	if blank {
		return h
	}
	return mix(mix(h, slot), fnv1a.sum64_string(d.text(i).trim_space()))
}

// repeat_key is an unkeyed item's key in a repeated role: its parent's name, its content's hash, and how many
// siblings of the role with that content come before it, so a document's own duplicates stay
// apart while an identical repetition in another document is the same items.
fn (mut ch ContentHashes) repeat_key(n flatxml.Node, children []string) string {
	k := ch.slot(n.doc)
	if ch.keys[k].len == 0 {
		ch.keys[k] = []string{len: n.doc.tag.len}
	}
	if ch.keys[k][n.i] != '' {
		return ch.keys[k][n.i]
	}
	// every child of the role under this parent, keyed at once
	d := n.doc
	p := d.parent[n.i]
	pname := ch.nm.name(d, p)
	mut seen := map[u64]int{}
	mut c := d.first_child(p)
	for c != flatxml.no_node {
		if d.is_element(c) && (children.len == 0 || ch.nm.name(d, c) in children) {
			h := ch.hash_at(k, d, c)
			ch.keys[k][c] = content_key(pname, h, seen[h])
			seen[h]++
		}
		c = d.next_sibling(c)
	}
	if ch.keys[k][n.i] == '' {
		ch.keys[k][n.i] = content_key(pname, ch.hash_at(k, d, n.i), 0)
	}
	return ch.keys[k][n.i]
}

// content_key is a content key: the parent's name (keys are unique in a scope, which may hold
// several single holders), the content's hash, and the identical siblings before it.
fn content_key(parent string, h u64, before int) string {
	return '${content_mark}${parent}${flatxml.key_sep}${hex16(h)}${flatxml.key_sep}${before}'
}

// hex16 is h as 16 lower-case hex digits, as `${h:016x}` writes it, without the general
// formatter: a content key is made for every item keyed by its content.
fn hex16(h u64) string {
	mut b := []u8{len: 16}
	for i in 0 .. 16 {
		b[15 - i] = '0123456789abcdef'[int((h >> (4 * i)) & 0xf)]
	}
	return b.bytestr()
}

// with_repeat_keys is a rule set whose unkeyed rules of repeated roles key their items by their
// content, so an identical repetition is one item.
pub fn with_repeat_keys(rs flatxml.RuleSet, repeat []int, mut ch ContentHashes) flatxml.RuleSet {
	if repeat.len == 0 {
		return rs
	}
	mut rules := rs.rules.clone()
	for k in repeat {
		if k < rules.len && rules[k].key.len == 0 && rules[k].key_fn == none && !rules[k].single {
			children := rules[k].children.clone()
			key_fn := fn [mut ch, children] (n flatxml.Node) ?string {
				return ch.repeat_key(n, children)
			}
			rules[k] = flatxml.Rule{
				...rules[k]
				key_fn: key_fn
			}
		}
	}
	return flatxml.RuleSet{
		...rs
		rules: rules
	}
}

// merge_rules is the rule set a merge of the models applies: value keys for identity roles, and
// content keys (by ch) for repeated roles.
pub fn (f &Flat) merge_rules(models []&Model, mut ch ContentHashes) flatxml.RuleSet {
	return with_repeat_keys(with_value_keys(f.rules, f.value_keys(models)), f.repeat_rules, mut
		ch)
}

// ignored_problem reports whether a merge problem lies in content the merge does not compare.
fn ignored_problem(v &flatxml.Merged, pr flatxml.Problem, ignored []string) bool {
	if ignored.len == 0 {
		return false
	}
	if pr.what in ignored {
		return true
	}
	return in_ignored(v.node(pr.node), ignored)
}

// in_ignored reports whether a node is, or lies in, an element not compared.
fn in_ignored(n flatxml.MNode, ignored []string) bool {
	mut cur := n
	for cur.ok() {
		if cur.name() in ignored {
			return true
		}
		cur = cur.parent()
	}
	return false
}

// short_name_parts is, for each rule whose key has a short name, the key part that is it; -1 for
// the others (keys of values, of content, of a definition).
fn short_name_parts(rules flatxml.RuleSet) []int {
	mut out := []int{cap: rules.rules.len}
	for r in rules.rules {
		out << if r.key_fn != none { -1 } else { r.key.index(short_name) }
	}
	return out
}

// case_only_findings are the children of one parent whose short names differ only in case:
// short names are unique ignoring case ([constr_2508]), compared as written by this policy.
fn case_only_findings(mut v flatxml.Merged, ix &PathIndex, rules flatxml.RuleSet, p Policy) []Finding {
	parts := short_name_parts(rules)
	mut out := []Finding{}
	for i in 0 .. v.len() {
		n := v.node(u32(i))
		if n.child_count() < 2 {
			continue
		}
		// the short names of the children whose rule keys by one
		mut shorts := []string{}
		mut ids := []u32{}
		for c in n.children() {
			// a child of a keyed rule missing its key has no short name to compare
			if !c.keyed() {
				continue
			}
			k := c.rule_number() or { continue }
			part := parts[k]
			if part < 0 {
				continue
			}
			key := c.key()
			sn := if part == 0 && !key.contains(flatxml.key_sep) {
				key
			} else {
				key.split(flatxml.key_sep)[part] or { '' }
			}
			if sn != '' {
				shorts << sn
				ids << c.i
			}
		}
		if shorts.len < 2 {
			continue
		}
		mut lows := shorts.map(it.to_lower_ascii())
		mut sorted := lows.clone()
		sorted.sort()
		mut clash := false
		for j in 1 .. sorted.len {
			if sorted[j] == sorted[j - 1] {
				clash = true
				break
			}
		}
		if !clash {
			continue
		}
		mut by := map[string][]string{}
		mut at_of := map[string][]u32{}
		for j, low in lows {
			if shorts[j] !in (by[low] or { []string{} }) {
				by[low] << shorts[j]
			}
			at_of[low] << ids[j]
		}
		for low, names in by {
			if names.len < 2 {
				continue
			}
			group := (at_of[low] or { []u32{} }).map(v.node(it))
			mut at := []string{}
			for c in group {
				at << c.fragments().map(v.pos(it))
			}
			what := group[0].name()
			out << Finding{
				layer:    .merge
				kind:     'case_only'
				what:     what
				severity: p.severity(.merge, 'case_only', what)
				path:     merged_path(n, ix)
				message:  'short names that differ only in case: ${names.join(', ')}'
				at:       at
			}
		}
	}
	return out
}

// repeated_findings check each merged element's repeated roles, by the rule flatxml applied to
// each child: every fragment of the element that holds the role holds the same items (in order
// where the role is ordered), and no fragment holds two of one key. A document may write the
// element twice, each time repeating the role identically.
fn repeated_findings(mut v flatxml.Merged, ix &PathIndex, rules flatxml.RuleSet, repeat []int, mut ch ContentHashes, p Policy) []Finding {
	if repeat.len == 0 {
		return []
	}
	mut is_repeat := []bool{len: rules.rules.len}
	for k in repeat {
		if k < is_repeat.len {
			is_repeat[k] = true
		}
	}
	mut out := []Finding{}
	for i in 0 .. v.len() {
		n := v.node(u32(i))
		if n.child_count() == 0 {
			continue
		}
		// a parent of one fragment: only an item written twice there can be wrong
		if n.fragment_count() < 2 {
			for c in n.children() {
				if c.fragment_count() < 2 {
					continue
				}
				k := c.rule_number() or { continue }
				if is_repeat[k] {
					out << collision_finding(mut v, ix, c, p)
				}
			}
			continue
		}
		mut any := false
		for c in n.children() {
			if k := c.rule_number() {
				if is_repeat[k] {
					any = true
					break
				}
			}
		}
		if !any {
			continue
		}
		// per repeated rule and fragment of n (its document and node): the hashes of its items
		mut seqs := map[u64][]u64{}
		mut rules_seen := []int{}
		for c in n.children() {
			k := c.rule_number() or { continue }
			if !is_repeat[k] {
				continue
			}
			if k !in rules_seen {
				rules_seen << k
			}
			mut parents := map[u64]bool{}
			for f in c.fragments() {
				pf := f.parent()
				id := u64(ch.slot(pf.doc)) << 32 | u64(pf.i)
				if id in parents {
					out << collision_finding(mut v, ix, c, p)
					break
				}
				parents[id] = true
				seqs[u64(k) << 48 | id] << ch.hash(f)
			}
		}
		for k in rules_seen {
			r := rules.rules[k]
			mut first := []u64{}
			mut started := false
			mut differs := false
			mut fragments := 0
			for key, hs in seqs {
				if int(key >> 48) != k {
					continue
				}
				fragments++
				mut items := hs.clone()
				if !r.ordered {
					items.sort()
				}
				if !started {
					first = items.clone()
					started = true
				} else if items != first {
					differs = true
				}
			}
			if differs {
				what := if r.children.len > 0 { r.children[0] } else { '*' }
				out << Finding{
					layer:    .merge
					kind:     'repeated_differs'
					what:     what
					severity: p.severity(.merge, 'repeated_differs', what)
					path:     merged_path(n, ix)
					message:  '${r.children.join(', ')}: a role that is not splittable, given differently by ${fragments} fragments'
					at:       n.fragments().map(v.pos(it))
				}
			}
		}
	}
	return out
}

// collision_finding is an item of a repeated role written twice in one fragment.
fn collision_finding(mut v flatxml.Merged, ix &PathIndex, c flatxml.MNode, p Policy) Finding {
	return Finding{
		layer:    .merge
		kind:     'collision'
		what:     c.name()
		severity: p.severity(.merge, 'collision', c.name())
		path:     merged_path(c, ix)
		message:  'two items of one key written together, in a role that is not splittable'
		at:       c.fragments().map(v.pos(it))
	}
}
