module arxmodel

import flatxml
import strings

// A diff by element: the changes of a diff gathered under the referrable element each lies in,
// as a configuration editor shows a model, element by element, each with its values.
//
// An element added or removed whole is one change, whatever it holds: its values are its rows,
// and the referrable elements in it are inside it, each likewise. Any other change is a row of the
// element it lies in, named below that element as `values` names a value: an ECUC parameter or
// reference value by its definition's last name (`Dim`), anything else by the elements below the
// element down to it (`ADMIN-DATA/SDGS/SDG/SD`), an attribute after `/@`. A list added or removed
// whole is a row for each value in it, and an element for each referrable element in it.

// diff_report_version is the version of diff's JSON report: a field removed or changed in meaning
// raises it, a field added does not.
pub const diff_report_version = 1

// DiffRow is one change in an element.
pub struct DiffRow {
pub:
	sign   string  // `+` added, `-` removed, `~` text, `@` attribute, `>` moved
	name   string  // below the element, '' for the element itself
	from   string  // `>`: its name where it was
	tag    string  // its element: the item's, for a value named by its definition
	before ?string // the old value; none where there was none
	after  ?string // the new value; none where there is none
	old_at string  // where it is in the old version; '' where it is not there
	new_at string  // where it is in the new version; '' where it is not there
}

// DiffElement is a referrable element that changed: added (`+`) or removed (`-`) whole, changed
// in (`~`), or moved from another path (`>`).
pub struct DiffElement {
pub mut:
	sign       string
	path       string // in the new version, in the old for a removal; `/` above every element
	from       string // `>`: the path it had
	tag        string
	definition string   // the definition it gives (an ECUC container's), '' where none
	origins    []string // the origins its annotations name
	old_at     string   // where it is in the old version; '' where it is not there
	new_at     string   // where it is in the new version; '' where it is not there
	rows       []DiffRow
	inside     []DiffElement // `+` and `-`: the referrable elements in it, in the order of the file
	xml        string        // `+` and `-`, where asked for: the element as the file has it
}

// ElementDiff is a diff by element.
pub struct ElementDiff {
pub:
	elements []DiffElement // by path
	changes  int           // the changes of the diff, as `Ruling.diff` gives them
}

@[params]
pub struct ElementDiffOptions {
pub:
	xml bool // each element added or removed whole as the file has it, too
}

// DiffSide is one version as a diff by element reads it: the values of each element, walked once.
struct DiffSide {
mut:
	v    &Version = unsafe { nil }
	w    ValueWalk
	seen map[u32][]Value
}

// values_of are the values of element el, not those of the referrable elements below it.
fn (mut s DiffSide) values_of(el flatxml.MNode) []Value {
	if have := s.seen[el.i] {
		return have
	}
	s.w.out = []Value{}
	s.w.walk_element(el, s.path(el))
	s.seen[el.i] = s.w.out
	return s.w.out
}

// path is an element's AUTOSAR path, '' for a node above every referrable element.
fn (s &DiffSide) path(el flatxml.MNode) string {
	return s.v.ix.path_of(el.i) or { '' }
}

// value_at is the value whose text node n is, in element el.
fn (mut s DiffSide) value_at(el flatxml.MNode, n flatxml.MNode) ?Value {
	for v in s.values_of(el) {
		if v.node == n.i {
			return v
		}
	}
	return none
}

// name_in is node n's name below element el: as its value is named, else by the elements down
// to it.
fn (mut s DiffSide) name_in(el flatxml.MNode, n flatxml.MNode) string {
	at := s.path(el)
	if v := s.value_at(el, n) {
		return part_below(v.path, at)
	}
	return part_below(merged_path(n, s.v.ix), at)
}

// element_of is the nearest referrable element at or above n; the root above every one.
fn (s &DiffSide) element_of(n flatxml.MNode) flatxml.MNode {
	mut cur := n
	mut last := n
	for cur.ok() {
		if s.referrable(cur) {
			return cur
		}
		last = cur
		cur = cur.parent()
	}
	return last
}

fn (s &DiffSide) referrable(n flatxml.MNode) bool {
	return n.ok() && int(n.i) < s.v.ix.at.len && s.v.ix.at[n.i] != 0
}

// part_below is a path's part below the path of its element: `Dim`, `ADMIN-DATA/SDGS`; '' for the
// element itself.
fn part_below(path string, el string) string {
	if !path.starts_with(el) {
		return path
	}
	rest := path[el.len..]
	return if rest.len > 0 && (rest[0] == `/` || rest[0] == `#`) { rest[1..] } else { rest }
}

// lies_in reports whether node n is top or lies below it.
fn lies_in(n flatxml.MNode, top flatxml.MNode) bool {
	mut cur := n
	for cur.ok() {
		if cur.i == top.i {
			return true
		}
		cur = cur.parent()
	}
	return false
}

fn some_if(cond bool, s string) ?string {
	if cond {
		return s
	}
	return none
}

// ElementBuild gathers the changes of a diff by element.
struct ElementBuild {
mut:
	sides [2]DiffSide // the old version and the new
	xml   bool
	els   []DiffElement
	by    map[string]int // a path -> its changed element in els
}

// diff_elements is what changed from version a to version b, by element.
pub fn (r &Ruling) diff_elements(a &Version, b &Version, opts ElementDiffOptions) ElementDiff {
	d := flatxml.diff(a.view, b.view)
	mut eb := ElementBuild{
		xml: opts.xml
	}
	eb.sides[0] = DiffSide{
		v: unsafe { a }
		w: value_walk_of(a.view, a.ix, &r.flat, '')
	}
	eb.sides[1] = DiffSide{
		v: unsafe { b }
		w: value_walk_of(b.view, b.ix, &r.flat, '')
	}
	mut count := 0
	for c in d.changes {
		if !r.counts(c) {
			continue
		}
		count++
		match c.kind {
			.added { eb.added(1, c.new) }
			.removed { eb.added(0, c.old) }
			.moved { eb.moved(c) }
			.text, .attr { eb.changed_in(c) }
		}
	}
	mut els := eb.els.clone()
	els.sort_with_compare(fn (x &DiffElement, y &DiffElement) int {
		return compare_strings(x.path, y.path)
	})
	// the changes in an element by name, as an editor lists values: by the first step of the name,
	// so what one list added or removed held stays together, in the order of its file; what an
	// element added or removed whole holds stays in that order too
	for mut e in els {
		if e.sign in ['~', '>'] {
			e.rows = by_first_step(e.rows)
		}
	}
	return ElementDiff{
		elements: els
		changes:  count
	}
}

// by_first_step is rows sorted by the first step of their names, rows of one step in the order
// they came.
fn by_first_step(rows []DiffRow) []DiffRow {
	mut order := []int{len: rows.len, init: index}
	order.sort_with_compare(fn [rows] (x &int, y &int) int {
		c := compare_strings(rows[*x].name.all_before('/'), rows[*y].name.all_before('/'))
		return if c != 0 { c } else { *x - *y }
	})
	return order.map(rows[it])
}

// changed is the changed element at old_n and new_n (either may be empty): made where there is
// none yet, the other version's element found by its path.
fn (mut eb ElementBuild) changed(old_n flatxml.MNode, new_n flatxml.MNode) int {
	mut oe := if old_n.ok() { eb.sides[0].element_of(old_n) } else { flatxml.MNode{} }
	mut ne := if new_n.ok() { eb.sides[1].element_of(new_n) } else { flatxml.MNode{} }
	at := if ne.ok() { eb.sides[1].path(ne) } else { eb.sides[0].path(oe) }
	key := if at == '' { '/' } else { at }
	if k := eb.by[key] {
		return k
	}
	if !oe.ok() {
		oe = eb.sides[0].holder(at)
	}
	if !ne.ok() {
		ne = eb.sides[1].holder(at)
	}
	el := if ne.ok() { ne } else { oe }
	s := if ne.ok() { 1 } else { 0 }
	vals := eb.sides[s].values_of(el)
	eb.els << DiffElement{
		sign:       '~'
		path:       key
		tag:        el.name()
		definition: eb.sides[s].w.definition_of(el)
		origins:    origins(vals, at)
		old_at:     if oe.ok() { oe.pos() } else { '' }
		new_at:     if ne.ok() { ne.pos() } else { '' }
	}
	eb.by[key] = eb.els.len - 1
	return eb.els.len - 1
}

// holder is the element at a path ('' the root); empty where there is none.
fn (s &DiffSide) holder(at string) flatxml.MNode {
	if at == '' {
		return s.v.view.root()
	}
	hs := s.v.ix.holders(at)
	return if hs.len > 0 { s.v.view.node(hs[0]) } else { flatxml.MNode{} }
}

// added files node n, added to the new version (s 1) or removed from the old (s 0): a referrable
// element as an element added or removed whole; anything else as the rows of the values in it,
// in the element it lies in, and the referrable elements in it whole.
fn (mut eb ElementBuild) added(s int, n flatxml.MNode) {
	sign := if s == 1 { '+' } else { '-' }
	if eb.sides[s].referrable(n) {
		eb.put(eb.whole(s, n, sign))
		return
	}
	el := eb.sides[s].element_of(n.parent())
	k := if s == 1 { eb.changed(flatxml.MNode{}, n) } else { eb.changed(n, flatxml.MNode{}) }
	at := eb.sides[s].path(el)
	mut any := false
	for v in eb.sides[s].values_of(el) {
		if lies_in(n.m.node(v.node), n) {
			eb.els[k].rows << eb.value_row(s, v, at, sign)
			any = true
		}
	}
	for inner in eb.sides[s].referrable_below(n) {
		eb.put(eb.whole(s, inner, sign))
		any = true
	}
	if !any {
		// an element holding no value
		eb.els[k].rows << DiffRow{
			sign:   sign
			name:   part_below(merged_path(n, eb.sides[s].v.ix), at)
			tag:    n.name()
			old_at: if s == 0 { n.pos() } else { '' }
			new_at: if s == 1 { n.pos() } else { '' }
		}
	}
}

// put adds an element added or removed whole.
fn (mut eb ElementBuild) put(e DiffElement) {
	eb.els << e
	if e.path !in eb.by {
		eb.by[e.path] = eb.els.len - 1
	}
}

// whole is referrable element n, added (s 1) or removed (s 0) whole, with its values and the
// referrable elements in it.
fn (mut eb ElementBuild) whole(s int, n flatxml.MNode, sign string) DiffElement {
	at := eb.sides[s].path(n)
	vals := eb.sides[s].values_of(n)
	mut e := DiffElement{
		sign:       sign
		path:       at
		tag:        n.name()
		definition: eb.sides[s].w.definition_of(n)
		origins:    origins(vals, at)
		old_at:     if s == 0 { n.pos() } else { '' }
		new_at:     if s == 1 { n.pos() } else { '' }
		xml:        if eb.xml { own_xml(n) } else { '' }
	}
	for v in vals {
		e.rows << eb.value_row(s, v, at, sign)
	}
	for inner in eb.sides[s].referrable_below(n) {
		mut ie := eb.whole(s, inner, sign)
		ie.xml = ''
		e.inside << ie
	}
	return e
}

// value_row is a value added (s 1) or removed (s 0), as a row of the element at path at.
fn (eb &ElementBuild) value_row(s int, v Value, at string, sign string) DiffRow {
	m := eb.sides[s].v.view
	n := m.node(v.node)
	return DiffRow{
		sign:   sign
		name:   part_below(v.path, at)
		tag:    tag_of(m, v)
		before: some_if(s == 0, v.text)
		after:  some_if(s == 1, v.text)
		old_at: if s == 0 { n.pos() } else { '' }
		new_at: if s == 1 { n.pos() } else { '' }
	}
}

// tag_of is a value's element: the item's, for a value named by its definition.
fn tag_of(m &flatxml.Merged, v Value) string {
	return if v.item != flatxml.no_mnode { m.node(v.item).name() } else { m.node(v.node).name() }
}

// referrable_below are the referrable elements below n with none between, in the order of the
// view.
fn (s &DiffSide) referrable_below(n flatxml.MNode) []flatxml.MNode {
	mut out := []flatxml.MNode{}
	for c in n.children() {
		if s.referrable(c) {
			out << c
		} else if c.child_count() > 0 {
			out << s.referrable_below(c)
		}
	}
	return out
}

// moved files a move: of a referrable element, as the element's (`>`, from its old path); of
// anything else, as each referrable element in it moved, and a row of the element it lies in
// where it holds a value of that element.
fn (mut eb ElementBuild) moved(c flatxml.Change) {
	if eb.sides[0].referrable(c.old) && eb.sides[1].referrable(c.new) {
		eb.move_element(c.old, c.new)
		return
	}
	// what moved is equal on both sides, so its referrable elements pair in order
	olds := eb.sides[0].referrable_below(c.old)
	news := eb.sides[1].referrable_below(c.new)
	if olds.len == news.len {
		for i, o in olds {
			eb.move_element(o, news[i])
		}
	}
	oe := eb.sides[0].element_of(c.old)
	ne := eb.sides[1].element_of(c.new)
	if news.len > 0 && !eb.sides[1].values_of(ne).any(lies_in(c.new.m.node(it.node), c.new)) {
		return
	}
	k := eb.changed(c.old, c.new)
	eb.els[k].rows << DiffRow{
		sign:   '>'
		name:   eb.sides[1].name_in(ne, c.new)
		from:   eb.sides[0].name_in(oe, c.old)
		tag:    c.new.name()
		old_at: c.old.pos()
		new_at: c.new.pos()
	}
}

// move_element files referrable element o of the old version as moved to n of the new.
fn (mut eb ElementBuild) move_element(o flatxml.MNode, n flatxml.MNode) {
	k := eb.changed(o, n)
	eb.els[k].sign = '>'
	eb.els[k].from = eb.sides[0].path(o)
}

// changed_in files a change of text or of an attribute as a row of the element it lies in.
fn (mut eb ElementBuild) changed_in(c flatxml.Change) {
	k := eb.changed(c.old, c.new)
	oe := eb.sides[0].element_of(c.old)
	ne := eb.sides[1].element_of(c.new)
	name := eb.sides[1].name_in(ne, c.new)
	if c.kind == .attr {
		eb.els[k].rows << DiffRow{
			sign:   '@'
			name:   if name == '' { '@${c.name}' } else { '${name}/@${c.name}' }
			tag:    c.new.name()
			before: c.before
			after:  c.after
			old_at: c.old.pos()
			new_at: c.new.pos()
		}
		return
	}
	ov := eb.sides[0].value_at(oe, c.old)
	nv := eb.sides[1].value_at(ne, c.new)
	eb.els[k].rows << DiffRow{
		sign:   '~'
		name:   name
		tag:    if v := nv { tag_of(eb.sides[1].v.view, v) } else { c.new.name() }
		before: if v := ov { v.text } else { c.before }
		after:  if v := nv { v.text } else { c.after }
		old_at: c.old.pos()
		new_at: c.new.pos()
	}
}

// origins are the origins an element's own annotations name, from its values.
fn origins(vals []Value, at string) []string {
	mut out := []string{}
	for v in vals {
		name := part_below(v.path, at)
		if name.starts_with('ANNOTATIONS/') && name.ends_with('/ANNOTATION-ORIGIN') && v.text != '' {
			out << v.text
		}
	}
	return out
}

// counts are the elements by how they changed: added, removed, changed and moved.
pub fn (d &ElementDiff) counts() (int, int, int, int) {
	mut a, mut r, mut c, mut m := 0, 0, 0, 0
	for e in d.elements {
		match e.sign {
			'+' { a++ }
			'-' { r++ }
			'>' { m++ }
			else { c++ }
		}
	}
	return a, r, c, m
}

// summary is the diff in one line: how many elements, and how they changed.
pub fn (d &ElementDiff) summary() string {
	a, r, c, m := d.counts()
	return '${plural_of(d.elements.len, 'element')}: ${a} added, ${r} removed, ${c} changed, ${m} moved'
}

fn plural_of(n int, word string) string {
	return '${n} ${word}${if n == 1 { '' } else { 's' }}'
}

// --- text --------------------------------------------------------------------------------------

// shown_cut is the most of a value one line of the text shows.
const shown_cut = 120

// text is the diff as lines: a line for each element, its sign, path, kind (its definition's last
// name, else its element) and, with at, where it is; for an element changed or moved, a line for
// each change in it below, indented. An element added or removed whole is its line alone, with
// how many elements it holds.
pub fn (d &ElementDiff) text(at bool) string {
	mut b := strings.new_builder(256 + d.elements.len * 128)
	for e in d.elements {
		b.write_string(e.sign)
		b.write_u8(` `)
		if e.sign == '>' {
			b.write_string('${e.from} -> ')
		}
		b.write_string(e.path)
		b.write_string('  ${e.kind()}')
		if e.inside.len > 0 {
			b.write_string(', ${e.inner_count()} inside')
		}
		if at {
			where := if e.new_at != '' { e.new_at } else { e.old_at }
			if where != '' {
				b.write_string('  ${where}')
			}
		}
		b.write_u8(`\n`)
		if e.sign in ['+', '-'] {
			continue
		}
		for r in e.rows {
			b.write_string('    ')
			b.write_string(match r.sign {
				'~', '@' { '${r.name}: ${shown_value(r.before)} -> ${shown_value(r.after)}' }
				'>' { '> ${r.from} -> ${r.name}' }
				else { r.added_line() }
			})
			b.write_u8(`\n`)
		}
	}
	return b.str()
}

// added_line is a row added or removed: its sign, name and value.
fn (r DiffRow) added_line() string {
	value := if r.sign == '-' { r.before } else { r.after }
	if v := value {
		return '${r.sign} ${r.name} = ${shown_value(v)}'
	}
	return '${r.sign} ${r.name}'
}

// kind is how the text names what an element is: its definition's last name, else its element.
pub fn (e &DiffElement) kind() string {
	if e.definition != '' {
		return e.definition.all_after_last('/')
	}
	return e.tag
}

// inner_count is how many elements are inside it, at any depth.
pub fn (e &DiffElement) inner_count() int {
	mut n := e.inside.len
	for i in e.inside {
		n += i.inner_count()
	}
	return n
}

// shown_value is a value as the text shows it: on one line, cut, `""` where empty, `(none)` where absent.
fn shown_value(s ?string) string {
	v := s or { return '(none)' }
	if v == '' {
		return '""'
	}
	one := v.replace('\r', '\\r').replace('\n', '\\n')
	return if one.len > shown_cut { one[..shown_cut - 3] + '...' } else { one }
}

// --- JSON --------------------------------------------------------------------------------------

// json is the diff as a report (docs/report.md).
pub fn (d &ElementDiff) json() string {
	a, r, c, m := d.counts()
	mut b := strings.new_builder(1024 + d.elements.len * 512)
	b.write_string('{"version":${diff_report_version},"tool":{"name":"arxmodel","version":${jstr(version)}},')
	b.write_string('"command":"diff","summary":{"elements":${d.elements.len},"added":${a},"removed":${r},')
	b.write_string('"changed":${c},"moved":${m},"changes":${d.changes}},"elements":[')
	for k, e in d.elements {
		if k > 0 {
			b.write_u8(`,`)
		}
		write_element_json(mut b, e)
	}
	b.write_string(']}\n')
	return b.str()
}

fn write_element_json(mut b strings.Builder, e DiffElement) {
	b.write_string('{"sign":${jstr(e.sign)},"path":${jstr(e.path)},"from":${jstr(e.from)},')
	b.write_string('"tag":${jstr(e.tag)},"definition":${jstr(e.definition)},')
	b.write_string('"origins":[${e.origins.map(jstr(it)).join(',')}],')
	b.write_string('"old":${location_json(e.old_at)},"new":${location_json(e.new_at)},"rows":[')
	for k, r in e.rows {
		if k > 0 {
			b.write_u8(`,`)
		}
		b.write_string('{"sign":${jstr(r.sign)},"name":${jstr(r.name)},"from":${jstr(r.from)},')
		b.write_string('"tag":${jstr(r.tag)},"before":${value_json(r.before)},"after":${value_json(r.after)},')
		b.write_string('"old":${location_json(r.old_at)},"new":${location_json(r.new_at)}}')
	}
	b.write_string('],"inside":[')
	for k, i in e.inside {
		if k > 0 {
			b.write_u8(`,`)
		}
		write_element_json(mut b, i)
	}
	b.write_u8(`]`)
	if e.xml != '' {
		b.write_string(',"xml":${jstr(e.xml)}')
	}
	b.write_u8(`}`)
}

// location_json is a place, `file:line:column`, as an object; null where there is none.
fn location_json(at string) string {
	if at == '' {
		return 'null'
	}
	l := parse_location(at)
	return '{"file":${jstr(l.file)},"line":${l.line},"column":${l.column}}'
}

fn value_json(s ?string) string {
	v := s or { return 'null' }
	return jstr(v)
}
