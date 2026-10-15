// xsd — XML Schema (XSD 1.0) compiled into flat tables.
//
// `load` reads one or more schema documents (and the documents they import) with flatxml and
// compiles them: every reference resolved, groups and attribute groups expanded, anonymous types
// numbered. It supports the subset of XSD listed in docs/plan.md and refuses everything else by
// name and position, never skipping a construct: a validator that ignores a constraint reports
// invalid documents as valid.
//
// Components live in arrays and refer to each other by index, the way the parser's nodes do.
module xsd

pub const xsd_ns_uri = 'http://www.w3.org/2001/XMLSchema'

// unbounded is maxOccurs="unbounded".
pub const unbounded = u32(0xFFFF_FFFF)

// QName is a namespace id and a local-name id, both in the schema's own tables.
pub struct QName {
pub:
	ns    u32
	local u32
}

@[inline]
fn (q QName) key() u64 {
	return u64(q.ns) << 32 | u64(q.local)
}

pub enum TypeKind {
	builtin
	simple
	complex
}

// TypeRef names a type: a built-in (idx is a `Builtin`), or an index into `simple_types` or
// `complex_types`.
pub struct TypeRef {
pub:
	kind TypeKind
	idx  u32
}

pub enum WhiteSpace {
	unset
	preserve
	replace
	collapse
}

pub struct SimpleType {
pub mut:
	name        QName // {0, 0} for an anonymous type
	base        TypeRef
	enums       []string
	patterns    []string  // as written
	compiled    []Pattern // the same, compiled
	root        Builtin   // the built-in type at the end of its derivation chain
	enum_keys   map[string]bool // its enumeration values by value (value_key), for lookup
	enum_qnames []string        // each enumeration value as {uri}local, by the schema's namespaces where it is written ('' when not a qualified name there)
	white_space WhiteSpace
	max_length  int = -1
}

pub enum Content {
	empty
	element_only
	mixed
	simple
}

pub struct ComplexType {
pub mut:
	name     QName // {0, 0} for an anonymous type
	abstract bool
	content  Content
	simple   TypeRef // the content's type when content is .simple
	particle u32     // the content model's root particle, `no_particle` when there is none
	attrs    []AttrUse
}

pub struct ElementDecl {
pub mut:
	name   QName
	typ    TypeRef
	global bool
}

pub struct AttrDecl {
pub mut:
	name   QName
	typ    TypeRef
	global bool
}

// AttrUse is an attribute a complex type allows: its declaration, and whether it is required.
pub struct AttrUse {
pub:
	decl     u32
	required bool
}

pub enum ParticleKind {
	element
	sequence
	choice
	group_ref // only while reading; resolution replaces every one
}

// Particle is a piece of a content model. An element particle's `term` is its declaration; a
// sequence or choice has `count` children, at `children[term .. term + count]`.
pub struct Particle {
pub mut:
	kind  ParticleKind
	min   u32 = 1
	max   u32 = 1
	term  u32
	count u32
}

pub const no_particle = u32(0)

// OwnerKind says what an annotation belongs to, and so what Appinfo's idx and sub mean.
pub enum OwnerKind {
	schema
	element         // idx: element declaration
	attribute       // idx: attribute declaration
	complex_type    // idx: complex type
	simple_type     // idx: simple type
	group           // idx: the group's root particle
	attribute_group // idx: index into the schema's attribute groups
	enumeration     // idx: simple type, sub: the value's index
	particle        // idx: a sequence, choice, element reference or group reference
	attribute_use   // idx: complex type, sub: the use's index (an attribute reference)
	group_attribute_use // idx: attribute group, sub: the use's index (an attribute reference)
	attribute_group_ref // idx: complex type, sub: the reference's ordinal in it
	group_attribute_group_ref // idx: attribute group, sub: the reference's ordinal in it
}

// Appinfo is one `xsd:appinfo`, kept for the consumer; nothing here interprets it. Its content
// is written back as XML (flatxml's inner_xml), so child elements survive as markup.
pub struct Appinfo {
pub:
	owner  OwnerKind
	idx    u32
	sub    u32
	source string
	text   string
}

@[heap]
pub struct Schema {
pub mut:
	names         []string // local names; id 0 is ''
	uris          []string // namespace URIs; id 0 is no namespace
	simple_types  []SimpleType
	complex_types []ComplexType
	elements      []ElementDecl
	attributes    []AttrDecl
	particles     []Particle // particle 0 is unused, so 0 can mean none
	children      []u32
	empties       []u8 // per particle: bit 0, one occurrence can be empty; bit 1, the particle can match nothing
	appinfo       []Appinfo
	files         []string // the schema documents read, in order
	notes         []string // what was read differently from how it is written: imports skipped
mut:
	name_ids      map[string]u32
	uri_ids       map[string]u32
	global_elems  map[u64]u32
	global_attrs  map[u64]u32
	named_simple  map[u64]u32
	named_complex map[u64]u32
	groups        map[u64]u32 // model group name -> its root particle
	attr_groups   map[u64]u32 // attribute group name -> index into agroups
	agroups       []AttrGroup
}

struct AttrGroup {
mut:
	attrs []AttrUse
	refs  []u32 // indices into the pending references naming other attribute groups
	done  bool
	busy  bool
}

// name_id is the id of a local name, if any component uses it.
pub fn (s &Schema) name_id(name string) ?u32 {
	return s.name_ids[name] or { return none }
}

// uri_id is the id of a namespace URI, if any component uses it.
pub fn (s &Schema) uri_id(uri string) ?u32 {
	return s.uri_ids[uri] or { return none }
}

// qname spells a name `{uri}local`, or `local` in no namespace.
pub fn (s &Schema) qname(q QName) string {
	return if q.ns == 0 { s.names[q.local] } else { '{${s.uris[q.ns]}}${s.names[q.local]}' }
}

// element is the global element declaration named {uri}local.
pub fn (s &Schema) element(uri string, local string) ?u32 {
	ns := s.uri_ids[uri] or { return none }
	l := s.name_ids[local] or { return none }
	return s.global_elems[QName{ns, l}.key()] or { return none }
}

// global_elements lists the global element declarations, in the order they were read.
pub fn (s &Schema) global_elements() []u32 {
	mut out := []u32{}
	for i, e in s.elements {
		if e.global {
			out << u32(i)
		}
	}
	return out
}

// complex_type_named is the named complex type {uri}local.
pub fn (s &Schema) complex_type_named(uri string, local string) ?u32 {
	ns := s.uri_ids[uri] or { return none }
	l := s.name_ids[local] or { return none }
	return s.named_complex[QName{ns, l}.key()] or { return none }
}

// simple_type_named is the named simple type {uri}local.
pub fn (s &Schema) simple_type_named(uri string, local string) ?u32 {
	ns := s.uri_ids[uri] or { return none }
	l := s.name_ids[local] or { return none }
	return s.named_simple[QName{ns, l}.key()] or { return none }
}

// particle_children are the children of a sequence or choice particle.
pub fn (s &Schema) particle_children(p u32) []u32 {
	pt := s.particles[p]
	if pt.kind == .element {
		return []
	}
	return s.children[pt.term..pt.term + pt.count]
}

fn (mut s Schema) intern_name(name string) u32 {
	if id := s.name_ids[name] {
		return id
	}
	id := u32(s.names.len)
	// a copy: names read from a document are views of its source, which is released after load
	owned := name.clone()
	s.names << owned
	s.name_ids[owned] = id
	return id
}

fn (mut s Schema) intern_uri(uri string) u32 {
	if id := s.uri_ids[uri] {
		return id
	}
	id := u32(s.uris.len)
	owned := uri.clone()
	s.uris << owned
	s.uri_ids[owned] = id
	return id
}
