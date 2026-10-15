module arxmodel

import flatxml

// The schema's rules as flatxml's. flatxml names an aggregation by its parent's and its
// children's element names; the schema by the parent's type and the role. So each rule here
// becomes flatxml rules per element name its holding type is declared with:
//
// - A role element that wraps its items is a single child of its holder, merged across
//   fragments, and the items are the wrapper's children: keyed by the split key (merged when
//   the role is splittable), else one child each. Item kinds of one rule are one flatxml rule
//   with several children, so ordered and the most hold across them.
// - A role element that is itself the item is keyed or one child each in the same way.
// - A role of one item (its most 1) is a single, merged child, whatever its key and its
//   splittability: its element is in every fragment of the object that holds it (a SHORT-NAME,
//   a VARIATION-POINT), and two fragments that disagree are reported as differing values.
// - A wrapper holding its items' content holds that content one child each, at most its most
//   items times as often as an item holds each.
// - A split key with a part that did not resolve is not used: one child each (the part is
//   reported by the rules already).
//
// One element pair can be given different rules by roles of different holder types (a
// CONTAINERS keyed under one class and not under another), which flatxml's names cannot tell
// apart. The documents settle a wrapper's items: where only one of the holders occurs above the
// pair, its rule is the rule. Every other such pair is a conflict: one rule is applied, and the
// view's problems on the pair are marked as the conflict's, not as violations.

// Flat is the flatxml rule set made from a schema's rules, and what could not be said in it.
pub struct Flat {
pub mut:
	rules     flatxml.RuleSet
	described []string // per rule, what it says (`key=SHORT-NAME merge`), its key included
	// element pairs roles give different rules: settled by the holders the documents use, or
	// left in conflict
	settled   []Conflict
	conflicts []Conflict // pairs in conflict that the documents use
	unused    []Conflict // pairs in conflict that no document uses: nothing to judge
	// rules whose items have no element of their own (flat wrappers)
	flat_wrappers int
	// keyed rules, whose keys are computed here: an item missing every key part has the empty
	// key, and a repeated element's every occurrence is read
	key_fns int
	// item kinds whose split key lost a part, so they are one child each
	lost_keys int
}

// Conflict is an element pair that roles of different holders give different rules.
pub struct Conflict {
pub:
	parent string
	child  string
	rules  []string // `role: rule (occurrences under its holders)`, the one applied first
	occurs int      // occurrences of the pair in the documents
}

@[params]
pub struct FlatOptions {
pub:
	case_sensitive bool     // keys compared as written; by default ignoring ASCII case
	ignore_attrs   []string // attributes whose values may differ between fragments
	// per element pair `parent child`, the names of the elements above the parent in the
	// documents and how often: what settles a pair several holders give different rules
	contexts map[string]map[string]int
}

// Spec is one flatxml rule before it is made.
struct Spec {
	single  bool
	merge   bool
	ordered bool
	max     int
	keyed   bool
	key     []string // flatxml key paths, '' for the item's own text; none: every item one key
	all     []bool   // per key path: every occurrence of its last step is part of the value
}

fn (a Spec) same(b Spec) bool {
	return a.single == b.single && a.merge == b.merge && a.ordered == b.ordered && a.max == b.max
		&& a.keyed == b.keyed && a.key == b.key && a.all == b.all
}

fn (s Spec) str() string {
	mut out := []string{}
	if s.keyed {
		if s.key.len == 0 {
			out << 'key=(one for all)'
		} else {
			mut ks := []string{}
			for k, p in s.key {
				v := if p == '' { '.' } else { p }
				ks << if s.all[k] { v + '*' } else { v }
			}
			out << 'key=' + ks.join(',')
		}
	} else if s.single {
		out << 'single'
	} else {
		out << 'each'
	}
	if s.merge {
		out << 'merge'
	}
	if s.ordered {
		out << 'ordered'
	}
	if s.max > 0 {
		out << 'max=${s.max}'
	}
	return out.join(' ')
}

// Cand is one rule's flatxml rule for an element pair, and the holders it applies under: the
// names of the elements above the pair's parent (none for a pair whose parent is the holder).
struct Cand {
	spec Spec
	rule int // index of the rule in the rule set
mut:
	above []string
}

fn flat_path(k KeyPath) string {
	return k.steps.join('/')
}

const single_merge = Spec{
	single: true
	merge:  true
}

fn flat_max(n u32) int {
	return if n == unbounded || n > u32(max_i32) { 0 } else { int(n) }
}

fn (rs &RuleSet) item_spec(r &Rule, it Item) Spec {
	if r.max <= 1 {
		return single_merge
	}
	if r.key_spec.len > 0 && !it.key_lost {
		return Spec{
			keyed:   true
			merge:   r.splittable
			ordered: r.ordered
			max:     flat_max(r.max)
			key:     it.key.map(flat_path(it))
			all:     it.key.map(it.all)
		}
	}
	return Spec{
		ordered: r.ordered
		max:     flat_max(r.max)
	}
}

// names_of is, per complex type, the element names declared with it.
fn (rs &RuleSet) names_of() map[u32][]string {
	mut out := map[u32][]string{}
	for name, types in rs.types_of {
		for t in types {
			mut list := (out[t] or { []string{} }).clone()
			list << name
			out[t] = list
		}
	}
	return out
}

// Cands is, per element pair `parent child`, every rule's flatxml rule for it, in the schema's
// order, and the pairs in the order first met.
struct Cands {
mut:
	by_pair   map[string][]Cand
	order     []string
	flats     int
	lost_keys int
}

// add adds a rule's flatxml rule for a pair; one rule reached through several holder names is
// one candidate.
fn (mut c Cands) add(pair string, x Cand) {
	mut list := (c.by_pair[pair] or { []Cand{} }).clone()
	for mut y in list {
		if y.rule == x.rule {
			y.above << x.above
			c.by_pair[pair] = list
			return
		}
	}
	if list.len == 0 {
		c.order << pair
	}
	list << x
	c.by_pair[pair] = list
}

fn (rs &RuleSet) candidates() Cands {
	names := rs.names_of()
	mut c := Cands{}
	// the anonymous types of wrappers holding their items' content: the roles in them repeat
	// once per item, so the wrapper's rule, not theirs, says how they go together
	mut flat_types := map[u32]bool{}
	for r in rs.rules {
		if r.flat {
			flat_types[rs.schema.elements[r.decl].typ.idx] = true
		}
	}
	for k, r in rs.rules {
		if r.flat {
			c.flats++
			per_item := rs.per_item(r.decl)
			for it in r.items {
				c.add('${r.element} ${it.element}', Cand{Spec{
					ordered: r.ordered
					max:     flat_max(sat_mul(r.max, per_item[it.decl] or { unbounded }))
				}, k, []string{}})
			}
		}
		mut holders := []string{}
		for ct in r.held_by {
			if ct in flat_types {
				continue
			}
			holders << names[ct] or { []string{} }
		}
		for h in holders {
			sp := if r.wrapper { single_merge } else { rs.item_spec(&r, r.items[0]) }
			c.add('${h} ${r.element}', Cand{sp, k, []string{}})
		}
		if r.wrapper && !r.flat {
			for it in r.items {
				if it.key_lost {
					c.lost_keys++
				}
				c.add('${r.element} ${it.element}', Cand{rs.item_spec(&r, it), k, holders.clone()})
			}
		}
	}
	return c
}

// per_item is, for a wrapper holding its items' content, how often one item holds each element.
fn (rs &RuleSet) per_item(d u32) map[u32]u32 {
	p := rs.content_particle(d) or { return map[u32]u32{} }
	kids := rs.schema.particle_children(p)
	mut occ := []Occ{}
	if kids.len == 1 && rs.schema.particles[kids[0]].kind != .element {
		// one item is one occurrence of the group inside the wrapper's repetition
		for k in rs.schema.particle_children(kids[0]) {
			rs.walk(k, 1, mut occ)
		}
	} else {
		// no group marks out an item: how often one holds an element is not known
		rs.walk(p, 1, mut occ)
		occ = occ.map(Occ{it.decl, unbounded})
	}
	mut out := map[u32]u32{}
	for o in occ {
		out[o.decl] = o.max
	}
	return out
}

// conflicting_pairs is the element pairs that rules give different flatxml rules.
pub fn (rs &RuleSet) conflicting_pairs() []string {
	c := rs.candidates()
	mut out := []string{}
	for pair in c.order {
		list := c.by_pair[pair] or { continue }
		if list.any(!it.spec.same(list[0].spec)) {
			out << pair
		}
	}
	return out
}

// contexts_of counts, for each of the pairs given, the names of the elements above the parent
// where the pair occurs in m's documents.
pub fn contexts_of(m &Model, pairs []string) map[string]map[string]int {
	tab := m.set.tab
	// the pairs as name ids: a child's id says whether to look at all
	mut wanted := map[u64]int{}
	mut is_child := []bool{len: tab.len()}
	for k, pair in pairs {
		pid := tab.id(pair.all_before(' ')) or { continue }
		cid := tab.id(pair.all_after(' ')) or { continue }
		wanted[u64(pid) << 32 | cid] = k
		is_child[cid] = true
	}
	mut counts := map[u64]int{} // (pair, name id above) -> occurrences
	for d in m.set.docs {
		for i in 2 .. d.len() {
			t := d.tag[i]
			if !is_child[t] {
				continue
			}
			p := d.parent[i]
			k := wanted[u64(d.tag[p]) << 32 | t] or { continue }
			g := d.parent[p]
			counts[u64(k) << 32 | (if g == 0 { u32(0) } else { d.tag[g] })]++
		}
	}
	mut out := map[string]map[string]int{}
	for key, n in counts {
		pair := pairs[int(key >> 32)]
		g := u32(key & 0xFFFF_FFFF)
		mut cnt := (out[pair] or { map[string]int{} }).clone()
		cnt[if g == 0 { '' } else { tab.name(g) }] = n
		out[pair] = cnt
	}
	return out
}

fn (rs &RuleSet) describe_cands(list []Cand, seen map[string]int) []string {
	return list.map(fn [rs, seen] (c Cand) string {
		mut n := 0
		for h in c.above {
			n += seen[h] or { 0 }
		}
		at := if c.above.len == 0 { '' } else { ' (${n} under its holders)' }
		return '${rs.rules[c.rule].name}: ${c.spec}${at}'
	})
}

// to_flat turns the rules into flatxml's.
pub fn (rs &RuleSet) to_flat(opts FlatOptions) Flat {
	c := rs.candidates()
	mut f := Flat{
		flat_wrappers: c.flats
		lost_keys:     c.lost_keys
	}
	// per pair, the spec applied and the rule it is applied for
	mut chosen := map[string]Cand{}
	for pair in c.order {
		list := c.by_pair[pair] or { continue }
		mut pick := list[0]
		if list.any(!it.spec.same(list[0].spec)) {
			seen := (opts.contexts[pair] or { map[string]int{} }).clone()
			// the rules whose holders the documents use above the pair
			used := list.filter(it.above.any(it in seen))
			mut total := 0
			for _, n in seen {
				total += n
			}
			x := Conflict{
				parent: pair.all_before(' ')
				child:  pair.all_after(' ')
				rules:  rs.describe_cands(if used.len > 0 { used } else { list }, seen)
				occurs: total
			}
			if used.len > 0 && used.all(it.spec.same(used[0].spec)) {
				pick = used[0]
				f.settled << x
			} else {
				if used.len > 0 {
					pick = used[0]
				}
				if total > 0 {
					f.conflicts << x
				} else {
					f.unused << x
				}
			}
		}
		chosen[pair] = pick
	}
	// pairs of one parent applied for one rule with one spec are one flatxml rule
	mut by_parent := map[string][]string{}
	for pair in c.order {
		parent := pair.all_before(' ')
		mut list := (by_parent[parent] or { []string{} }).clone()
		list << pair
		by_parent[parent] = list
	}
	mut rules := []flatxml.Rule{}
	mut done := map[string]bool{}
	for pair in c.order {
		if pair in done {
			continue
		}
		pick := chosen[pair] or { continue }
		parent := pair.all_before(' ')
		mut children := []string{}
		for other in by_parent[parent] or { []string{} } {
			if other in done {
				continue
			}
			o := chosen[other] or { continue }
			if o.rule == pick.rule && o.spec.same(pick.spec) {
				children << other.all_after(' ')
				done[other] = true
			}
		}
		sp := pick.spec
		mut key_fn := ?flatxml.KeyFn(none)
		if sp.keyed {
			// computed, so that an item missing every part has the empty key
			key_fn = key_reader(sp.key, sp.all)
			f.key_fns++
		}
		f.described << sp.str()
		rules << flatxml.Rule{
			parent:   parent
			children: children
			key_fn:   key_fn
			single:   sp.single
			merge:    sp.merge
			ordered:  sp.ordered
			max:      sp.max
		}
	}
	f.rules = flatxml.RuleSet{
		rules:        rules
		fold:         !opts.case_sensitive
		ignore_attrs: opts.ignore_attrs
	}
	return f
}

// value_sep joins the values of a repeated key element; XML text cannot hold it, and it is not
// flatxml's key_sep, so a list of values never reads like another list or like several parts.
const value_sep = '\x1e'

// key_reader computes an item's key from its paths: the text at each path (the item's own text
// for ''), an attribute (`@NAME`, `A/@NAME`), or for a path whose last step repeats, every
// occurrence in order. A part that is absent reads as '', and so does a key with no part at all:
// items whose every part is absent share one empty key, so their fragments merge and what differs
// between them is reported. (This moves to flatxml's per-rule choice for an absent key once it
// is there; flatxml's own key paths leave such an item as one of its own.)
fn key_reader(paths []string, all []bool) flatxml.KeyFn {
	mut cache := &KeyCache{}
	for k, p in paths {
		cache.steps << KeyStep.of(p, all[k])
	}
	return fn [mut cache] (n flatxml.Node) ?string {
		if cache.steps.len == 0 {
			return ''
		}
		if voidptr(n.doc.tab) != voidptr(cache.tab) {
			cache.compile(n.doc.tab)
		}
		mut parts := []string{len: cache.steps.len}
		for k, st in cache.steps {
			holder := if st.holder.len == 0 { n } else { n.find(cache.paths[k]) }
			if !holder.ok() {
				continue
			}
			parts[k] = match st.kind {
				.text {
					holder.text()
				}
				.attr {
					holder.attr(st.leaf)
				}
				.all {
					mut vals := []string{}
					for c in holder.children_named(st.leaf) {
						vals << c.text()
					}
					vals.join(value_sep)
				}
			}
		}
		return parts.join(flatxml.key_sep)
	}
}

enum StepKind {
	text // the text at the path
	attr // an attribute of the element at the path
	all  // every child of one name of the element at the path
}

// KeyStep is one key path, split into the element it reads from (holder, '' for the item) and
// what it reads there.
struct KeyStep {
	holder string
	kind   StepKind
	leaf   string // the attribute's or the repeated child's name
}

fn KeyStep.of(p string, all bool) KeyStep {
	if p.contains('@') {
		return KeyStep{p.all_before('@').trim_right('/'), .attr, p.all_after('@')}
	}
	if all {
		return KeyStep{if p.contains('/') { p.all_before_last('/') } else { '' }, .all, p.all_after_last('/')}
	}
	return KeyStep{p, .text, ''}
}

// KeyCache keeps a key's holder paths compiled for the name table they were compiled against.
@[heap]
struct KeyCache {
mut:
	steps []KeyStep
	tab   &flatxml.Names = unsafe { nil }
	paths []flatxml.Path
}

fn (mut c KeyCache) compile(tab &flatxml.Names) {
	c.tab = tab
	c.paths = c.steps.map(tab.path(it.holder))
}

// declaration_attrs lists the attribute names, as written, that declare namespaces or belong to
// the XML Schema instance namespace (a schema location): they say how a file is written, not what
// it holds, so fragments may differ in them.
pub fn declaration_attrs(m &Model) []string {
	mut seen := map[string]bool{}
	for d in m.set.docs {
		lo, hi := d.attr_range(d.root())
		for a := lo; a < hi; a++ {
			if d.is_ns_decl(a) || d.ns_uri(d.attr_ns_of(a)) == xsi_ns_uri {
				seen[d.attr_name(a)] = true
			}
		}
	}
	mut out := seen.keys()
	out.sort()
	return out
}

// CheckOptions are the choices of a merge.
@[params]
pub struct CheckOptions {
pub:
	case_sensitive bool
	ignore_attrs   []string // besides namespace declarations and xsi attributes
}

// Checked is a model merged by its governing schema's rules.
pub struct Checked {
pub mut:
	governing string   // the governing schema's name
	pairs     []string // element pairs roles of different holders give different rules
	flat      Flat
	view      &flatxml.Merged = unsafe { nil }
	// per problem of the view: it lies on an element pair in conflict, so the rule that judged
	// it may not be the pair's, and it is not counted as a violation
	in_conflict []bool
	violations  int
	elements    int // elements in all documents
	merged      int // merged nodes made of more than one element
	within      int // of those, nodes two of whose elements are in one document
}

// check merges m's documents by the rules of the schema governing their namespace. One model
// has one namespace; a namespace no schema governs is an error.
pub fn check(m &Model, sc &Schemas, opts CheckOptions) !Checked {
	if sc.governing.len != 1 {
		return error('${sc.governing.len} namespaces declared; one model has one')
	}
	g := sc.governing[0]
	if g.use < 0 {
		return error('no schema governs ${g.ns}: ${g.note}')
	}
	gov := sc.uses[g.use]
	mut ignore := opts.ignore_attrs.clone()
	ignore << declaration_attrs(m)
	pairs := gov.rules.conflicting_pairs()
	flat := gov.rules.to_flat(
		case_sensitive: opts.case_sensitive
		ignore_attrs:   ignore
		contexts:       contexts_of(m, pairs)
	)
	mut view := m.set.merge(flat.rules)!
	mut merged, mut within := 0, 0
	for i in 0 .. view.len() {
		n := view.node(u32(i))
		if n.fragment_count() > 1 {
			merged++
			frags := n.fragments()
			mut docs := map[voidptr]bool{}
			for fr in frags {
				docs[voidptr(fr.doc)] = true
			}
			if docs.len < frags.len {
				within++
			}
		}
	}
	mut conflicted := map[string]bool{}
	for x in flat.conflicts {
		conflicted['${x.parent} ${x.child}'] = true
	}
	mut in_conflict := []bool{len: view.problems.len}
	mut violations := 0
	for k, p in view.problems {
		node := view.node(p.node)
		pair := if p.kind == .value_differs {
			'${node.parent().name()} ${node.name()}'
		} else {
			'${node.name()} ${p.what}'
		}
		in_conflict[k] = pair in conflicted
		if !in_conflict[k] {
			violations++
		}
	}
	return Checked{
		governing:   gov.name
		pairs:       pairs
		flat:        flat
		view:        view
		in_conflict: in_conflict
		violations:  violations
		elements:    m.element_count()
		merged:      merged
		within:      within
	}
}
