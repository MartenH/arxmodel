module arxmodel

import crypto.sha256
import flatxml
import strings

// Comparing versions of a model: a semantic diff, and a three-way merge, by AUTOSAR path.
//
// Every version is merged by the same rules (flatxml's merged view), so what is compared is the
// model, not its files: where an element is written, and in which order the items of an
// aggregation whose order means nothing come, are not changes. Neither are the attributes the
// merge lets differ (UUID, namespace declarations, xsi: attributes). Changes and conflicts are
// named by AUTOSAR path, as findings are.

// Ruling is what every version of a model is read by when versions are compared: the merge rules,
// the settings, and the schema's types where there is a schema.
pub struct Ruling {
pub mut:
	flat   Flat
	name   string // the governing schema, or the schema the rules file was made from
	fold   bool
	ignore []string // attributes whose values may differ, by name
	typing &Typing = unsafe { nil } // nil when the rules come from a rules file
	// per child element name, the rules naming it (or naming any child)
	by_child map[string][]int
	builtin  bool // the built-in identity rules (identity.toml), not a schema's
}

// ruling_builtin reads versions by the built-in identity rules: no schema needed.
pub fn ruling_builtin(models []&Model, st Settings, opts CheckOptions) Ruling {
	mut r := new_ruling(identity_flat(builtin_identity(), models), 'built-in identity rules', st, unsafe { nil },
		models, opts)
	r.builtin = true
	return r
}

// ruling_by_schema reads versions by the rules of the newest release any of them declares,
// compiled from dir.
pub fn ruling_by_schema(models []&Model, dir string, p Policy, opts CheckOptions) !Ruling {
	sc := compile_schemas(models[newest_declaring(models)], dir, policy: p)
	flat, name := governing_flat(sc)!
	gov := governing_use(sc)!
	return new_ruling(flat, name, p.settings(), new_typing(gov.schema), models, opts)
}

// newest_declaring is the model, of several versions, that declares the newest release: its
// schemas govern them all.
pub fn newest_declaring(models []&Model) int {
	mut pick := 0
	mut best := Release{}
	mut have := false
	for k, m in models {
		for u in declare_schemas(m).uses {
			r := release_of(u.name) or { continue }
			if !have || (r.prefix == best.prefix && r.compare(best) > 0) {
				best, pick, have = r, k, true
			}
		}
	}
	return pick
}

// ruling_by_rules reads versions by the rules of a rules file.
pub fn ruling_by_rules(flat Flat, name string, st Settings, models []&Model, opts CheckOptions) Ruling {
	return new_ruling(flat, name, st, unsafe { nil }, models, opts)
}

// new_ruling reads versions by a flat rule set: the items of identity roles keyed by what all the
// versions hold, so one definition reads alike in each.
pub fn new_ruling(flat0 Flat, name string, st Settings, ty &Typing, models []&Model, opts CheckOptions) Ruling {
	mut r := Ruling{
		name:   name
		typing: ty
	}
	// the settings, the declaration attributes of every version together
	for m in models {
		fold, ignore := st.apply(m, opts)
		r.fold = fold
		for a in ignore {
			if a !in r.ignore {
				r.ignore << a
			}
		}
	}
	mut flat := flat0
	flat.rules = with_settings(flat0.rules, r.fold, r.ignore)
	mut ch := new_content_hashes(r.ignore, naming(flat.rules.local_ns, models))
	ch.observe_ignored(models)
	flat.rules = flat.merge_rules(models, mut ch)
	r.flat = flat
	for k, rule in flat.rules.rules {
		children := if rule.children.len == 0 { ['*'] } else { rule.children }
		for c in children {
			r.by_child[c] << k
		}
	}
	return r
}

// Version is one version of a model, merged by a ruling, with its AUTOSAR paths.
pub struct Version {
pub mut:
	model &Model          = unsafe { nil }
	view  &flatxml.Merged = unsafe { nil }
	ix    &PathIndex      = unsafe { nil }
}

// read merges a version by the ruling.
pub fn (r &Ruling) read(m &Model) !Version {
	view := m.set.merge(with_settings(r.flat.rules, r.fold, r.ignore))!
	typed := r.typing != unsafe { nil }
	mut ty := if typed { r.typing } else { &Typing{} }
	return Version{
		model: m
		view:  view
		ix:    index_paths(view, mut ty, typed, r.fold)
	}
}

// empty_model is a model of no file: a version that does not exist, compared as empty.
pub fn empty_model() &Model {
	return &Model{
		set: flatxml.DocSet.new()
	}
}

// ordered reports whether the order of n among its siblings means something: by the most specific
// rule naming n under its parent (a longer parent path first, a rule for n's name before one for
// any child). A child no rule names is kept as written, so its order counts. By the built-in
// rules, the order of a named element does not count, and any other's does.
fn (r &Ruling) ordered(n flatxml.MNode) bool {
	if r.builtin {
		// a named element's order does not count; any other's does
		return flatxml.empty_key(n.key())
	}
	mut best := -1
	mut score := -1
	for name in [n.name(), '*'] {
		for k in r.by_child[name] or { continue } {
			depth := parent_depth(r.flat.rules.rules[k].parent, n.parent())
			if depth < 0 {
				continue
			}
			s := depth * 2 + if name == '*' { 0 } else { 1 }
			if s > score {
				best, score = k, s
			}
		}
	}
	return if best >= 0 { r.flat.rules.rules[best].ordered } else { true }
}

// parent_depth is how many names of a rule's parent (a name, or a path of ancestor names ending at
// the parent) match the node and its ancestors: 0 for a rule of any parent, -1 when it does not
// match (a class is not matched here).
fn parent_depth(spec string, parent flatxml.MNode) int {
	if spec == '' || spec == '*' {
		return 0
	}
	if spec.starts_with('%') {
		return -1
	}
	names := spec.split('/')
	mut cur := parent
	for j := names.len - 1; j >= 0; j-- {
		if !cur.ok() || cur.name() != names[j] {
			return -1
		}
		cur = cur.parent()
	}
	return names.len
}

// reordered reports whether a change only moves a node among the same siblings in an
// aggregation whose order means nothing: not a change of the model.
fn (r &Ruling) reordered(c flatxml.Change) bool {
	return c.kind == .moved && c.parent.ok() && c.old.parent().ok()
		&& c.old.parent().i == c.parent.i && !r.ordered(c.old)
}

// in_ignored_content reports whether a change lies in content a merge does not compare
// (structured comments, by the policy).
fn (r &Ruling) in_ignored_content(c flatxml.Change) bool {
	if r.flat.ignored_content.len == 0 {
		return false
	}
	mut cur := if c.new.ok() { c.new } else { c.old }
	for cur.ok() {
		if cur.name() in r.flat.ignored_content {
			return true
		}
		cur = cur.parent()
	}
	return false
}

// ignored reports whether a change is one of an attribute the merge lets differ.
fn (r &Ruling) ignored(c flatxml.Change) bool {
	return c.kind == .attr && (c.name in r.ignore || c.old_name in r.ignore)
}

// PathChange is one change of a diff, by AUTOSAR path.
pub struct PathChange {
pub:
	kind   flatxml.ChangeKind
	path   string  // the node's path: in the old version, or in the new one for an addition
	to     string  // moved: its path in the new version
	name   string  // attr: the attribute
	before ?string // text and attr: the old value, none when absent
	after  ?string // text and attr: the new value, none when gone
	at     string  // where the node is: in the old version, or the new one for an addition
	to_at  string  // moved, text and attr: where it is in the new version
}

// line is a change in one line: a sign, the path, what changed, and where.
pub fn (c PathChange) line() string {
	return match c.kind {
		.removed { '- ${c.path}  ${c.at}' }
		.added { '+ ${c.path}  ${c.at}' }
		.moved { '> ${c.path} -> ${c.to}  ${c.at} -> ${c.to_at}' }
		.text { '~ ${c.path}: ${show(c.before)} -> ${show(c.after)}  ${c.at} -> ${c.to_at}' }
		.attr {
			'@ ${c.path} @${c.name}: ${show(c.before)} -> ${show(c.after)}  ${c.at} -> ${c.to_at}'
		}
	}
}

fn show(s ?string) string {
	v := s or { return '(none)' }
	cut := if v.len > 80 { v[..77] + '...' } else { v }
	return '"' + cut.replace('\n', '\\n') + '"'
}

// diff is what changed from version a to version b, by AUTOSAR path.
pub fn (r &Ruling) diff(a &Version, b &Version) []PathChange {
	mut d := flatxml.diff(a.view, b.view)
	mut out := []PathChange{}
	for c in d.changes {
		if r.reordered(c) || r.ignored(c) || r.in_ignored_content(c) {
			continue
		}
		out << match c.kind {
			.added {
				PathChange{
					kind: c.kind
					path: merged_path(c.new, b.ix)
					at:   d.pos(c.new)
				}
			}
			.removed {
				PathChange{
					kind: c.kind
					path: merged_path(c.old, a.ix)
					at:   d.pos(c.old)
				}
			}
			else {
				PathChange{
					kind:   c.kind
					path:   merged_path(c.old, a.ix)
					to:     merged_path(c.new, b.ix)
					name:   c.name
					before: c.before
					after:  c.after
					at:     d.pos(c.old)
					to_at:  d.pos(c.new)
				}
			}
		}
	}
	return out
}

// merge3_report_version is the version of the merge's JSON report: a field removed or changed in
// meaning raises it, a field added does not.
pub const merge3_report_version = 1

// context_limit is the most of a file a conflict's report gives for one version.
const context_limit = 64 * 1024

// ConflictSide is what one version has at a conflict.
pub struct ConflictSide {
pub:
	value ?string // the text or attribute value, where the conflict is about one
	xml   string  // the element around the node as the file has it ('' where the version has no node)
	cut   bool    // xml is only the start of an element too long to give whole
}

// PathConflict is a node two versions change differently, by its AUTOSAR path in the base.
pub struct PathConflict {
pub:
	// the same for the same conflict in another run or on another machine, and not for one whose
	// sides have since changed: a decision made on it (`parse_decisions`) cannot land on another
	id        string
	kind      flatxml.ConflictKind
	path      string
	name      string // attr: the attribute's name
	what      string // what each side made of it
	base_at   string
	ours_at   string // '-' where ours removed it
	theirs_at string
	base      ConflictSide
	ours      ConflictSide
	theirs    ConflictSide
}

// line is a conflict in one line.
pub fn (c PathConflict) line() string {
	return '! ${c.path}: ${c.what}  base ${c.base_at}, ours ${c.ours_at}, theirs ${c.theirs_at}'
}

// Merged3 is a three-way merge by a ruling: flatxml's merge (whose edits on the base's documents
// are the result, holding ours where the sides conflict) and its conflicts by AUTOSAR path.
pub struct Merged3 {
pub mut:
	m3        flatxml.Merge3
	conflicts []PathConflict // those no decision settled
	resolved  int            // the conflicts decisions settled
	unused    []string       // the decisions that met no conflict, by id, sorted
}

// Take is the side a decision takes at a conflict.
pub enum Take {
	ours
	theirs
}

@[params]
pub struct Merge3Options {
pub:
	decisions map[string]Take // by `PathConflict.id`
}

// Decided is the decisions a merge used: a heap object, so that a callback can add to it.
@[heap]
struct Decided {
mut:
	used map[string]bool
}

// merge3 merges ours and theirs, two changed versions of base. A conflict about an attribute the
// merge lets differ, or two sides putting unordered items in different orders, is not one. A
// decision settles the conflict it names; the result holds the side it takes.
pub fn (r &Ruling) merge3(base &Version, ours &Version, theirs &Version, opts Merge3Options) !Merged3 {
	decisions := opts.decisions
	mut decided := &Decided{}
	mut m3 := if decisions.len == 0 {
		flatxml.merge3(base.view, ours.view, theirs.view)!
	} else {
		flatxml.merge3(base.view, ours.view, theirs.view,
			take_theirs: fn [r, base, ours, theirs, decisions, mut decided] (c flatxml.Conflict) bool {
				p := r.path_conflict(c, base, ours, theirs) or { return false }
				take := decisions[p.id] or { return false }
				decided.used[p.id] = true
				return take == .theirs
			}
		)!
	}
	mut out := []PathConflict{}
	for c in m3.conflicts {
		p := r.path_conflict(c, base, ours, theirs) or { continue }
		if take := decisions[p.id] {
			if take == .ours {
				decided.used[p.id] = true
				continue
			}
		}
		out << p
	}
	mut unused := decisions.keys().filter(it !in decided.used)
	unused.sort()
	return Merged3{
		m3:        m3
		conflicts: out
		resolved:  decided.used.len
		unused:    unused
	}
}

// path_conflict is a conflict by AUTOSAR path; none where it is no conflict to the ruling.
fn (r &Ruling) path_conflict(c flatxml.Conflict, base &Version, ours &Version, theirs &Version) ?PathConflict {
	if c.kind == .attr && c.name in r.ignore {
		return none
	}
	// structured comments are not compared, by the policy: ours is kept
	if r.flat.ignored_content.len > 0 && in_ignored(c.node, r.flat.ignored_content) {
		return none
	}
	if c.kind == .moved && r.reordered(c.ours) && r.reordered(c.theirs) {
		return none
	}
	what := match c.kind {
		.text {
			'text ${show(c.ours.after)} / ${show(c.theirs.after)}'
		}
		.attr {
			'@${c.name} ${show(c.ours.after)} / ${show(c.theirs.after)}'
		}
		.removed {
			'removed on one side, changed on the other (${c.ours.kind} / ${c.theirs.kind})'
		}
		.moved {
			'moved on both sides (${side_path(c.ours, ours)} / ${side_path(c.theirs, theirs)})'
		}
		.added {
			'two of one identity added (${merged_path(c.ours.new, ours.ix)} / ${merged_path(c.theirs.new, theirs.ix)})'
		}
	}
	path := merged_path(c.node, base.ix)
	return PathConflict{
		id:        conflict_id(c, path)
		kind:      c.kind
		path:      path
		name:      c.name
		what:      what
		base_at:   c.node.pos()
		ours_at:   if c.ours.new.ok() { c.ours.new.pos() } else { '-' }
		theirs_at: if c.theirs.new.ok() { c.theirs.new.pos() } else { '-' }
		base:      conflict_side(c.node, c.ours.before)
		ours:      conflict_side(c.ours.new, c.ours.after)
		theirs:    conflict_side(c.theirs.new, c.theirs.after)
	}
}

// conflict_id is a hash of what a conflict is: where, and what each side made of it. Where a
// node lies in a file is left out, and so are the files' names, which are git's temporary ones
// in a merge driver.
fn conflict_id(c flatxml.Conflict, path string) string {
	mut parts := ['${c.kind}', path, c.name]
	for side in [c.ours, c.theirs] {
		parts << '${side.kind}'
		parts << side.after or { '' }
		parts << if side.new.ok() { own_xml(side.new) } else { '' }
	}
	return sha256.sum(parts.join('\0').bytes()).hex()[..16]
}

// own_xml is a node as the file has it.
fn own_xml(n flatxml.MNode) string {
	f := n.fragment(0)
	i := if f.doc.is_text(f.i) { f.doc.parent[f.i] } else { f.i }
	return f.doc.source_xml(i)
}

// conflict_side is what a version has at a conflict; nothing where it has no such node.
fn conflict_side(n flatxml.MNode, value ?string) ConflictSide {
	if !n.ok() {
		return ConflictSide{
			value: value
		}
	}
	xml, cut := context_of(n)
	return ConflictSide{
		value: value
		xml:   xml
		cut:   cut
	}
}

// context_of is the element around a node, as the file has it: its parent; the node itself where
// the parent is more than context_limit, or the root; and the start of that where it is too.
fn context_of(n flatxml.MNode) (string, bool) {
	f := n.fragment(0)
	d := f.doc
	i := if d.is_text(f.i) { d.parent[f.i] } else { f.i }
	p := d.parent[i]
	if p != 0 {
		lo, hi := d.source_span(p)
		if hi - lo <= context_limit {
			return d.source_xml(p), false
		}
	}
	lo, hi := d.source_span(i)
	if hi - lo <= context_limit {
		return d.source_xml(i), false
	}
	return d.source_xml(i)[..context_limit], true
}

// parse_decisions reads a decisions file: `ours ID` or `theirs ID` a line, ID a conflict's id; `#`
// starts a comment, and a line may be empty.
pub fn parse_decisions(text string) !map[string]Take {
	mut out := map[string]Take{}
	for k, raw in text.split_into_lines() {
		line := raw.all_before('#').trim_space()
		if line == '' {
			continue
		}
		fields := line.fields()
		if fields.len != 2 || fields[0] !in ['ours', 'theirs'] {
			return error('line ${k + 1}: not `ours ID` or `theirs ID`: ${line}')
		}
		take := if fields[0] == 'ours' { Take.ours } else { Take.theirs }
		if was := out[fields[1]] {
			if was != take {
				return error('line ${k + 1}: ${fields[1]} is decided both ways')
			}
		}
		out[fields[1]] = take
	}
	return out
}

// json is the merge as a report (docs/report.md).
pub fn (m &Merged3) json() string {
	mut b := strings.new_builder(1024 + m.conflicts.len * 512)
	b.write_string('{"version":${merge3_report_version},"tool":{"name":"arxmodel","version":${jstr(version)}},')
	b.write_string('"command":"merge3","summary":{"conflicts":${m.conflicts.len},"resolved":${m.resolved},')
	b.write_string('"unused":[${m.unused.map(jstr(it)).join(',')}],')
	b.write_string('"ours_changes":${m.m3.ours.changes.len},"theirs_taken":${m.m3.taken}},"conflicts":[')
	for k, c in m.conflicts {
		if k > 0 {
			b.write_u8(`,`)
		}
		b.write_string('{"id":${jstr(c.id)},"kind":${jstr(c.kind.str())},"path":${jstr(c.path)},')
		b.write_string('"name":${jstr(c.name)},"what":${jstr(c.what)},')
		b.write_string('"base":${side_json(c.base_at, c.base)},"ours":${side_json(c.ours_at, c.ours)},')
		b.write_string('"theirs":${side_json(c.theirs_at, c.theirs)}}')
	}
	b.write_string(']}\n')
	return b.str()
}

// side_json is one version at a conflict; null where it has no such node.
fn side_json(at string, s ConflictSide) string {
	if at == '-' {
		return 'null'
	}
	l := parse_location(at)
	value := if v := s.value { jstr(v) } else { 'null' }
	return '{"file":${jstr(l.file)},"line":${l.line},"column":${l.column},"value":${value},"xml":${jstr(s.xml)},"cut":${s.cut}}'
}

// side_path is where a side's change puts a node: its path in that side's version, or `removed`.
fn side_path(c flatxml.Change, v &Version) string {
	return if c.new.ok() { '${c.kind} to ${merged_path(c.new, v.ix)}' } else { '${c.kind}' }
}
