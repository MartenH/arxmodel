module arxmodel

import flatxml
import strings

// Reports: what a check found, as a document a machine reads. The same Report is written as
// arxmodel's own JSON (docs/report.md, docs/report.schema.json), as SARIF 2.1.0 and as JUnit XML,
// so a command that finds things (check now, others later) fills a Report and picks a format.

// report_version is the version of arxmodel's JSON report format: a field removed or changed in
// meaning raises it, a field added does not.
pub const report_version = 1

// report_formats are the formats a Report is written in, besides text.
pub const report_formats = ['json', 'sarif', 'junit']

// Location is a place in a file: line and column from 1, 0 where unknown.
pub struct Location {
pub:
	file   string
	line   int
	column int
}

// parse_location reads `file:line:column` as findings write it, from the right, so a file name
// with a colon in it (a Windows drive) is kept whole.
pub fn parse_location(s string) Location {
	c := s.last_index(':') or {
		return Location{
			file: s
		}
	}
	l := s[..c].last_index(':') or {
		return Location{
			file: s
		}
	}
	line, col := s[l + 1..c], s[c + 1..]
	if line == '' || col == '' || !line.is_int() || !col.is_int() {
		return Location{
			file: s
		}
	}
	return Location{
		file:   s[..l]
		line:   line.int()
		column: col.int()
	}
}

// InputProblem is what kept files from being checked: a file not read (where the parser stopped,
// when it says), one declaring no schema, or a model no schema governs.
pub struct InputProblem {
pub:
	kind    string // `not_read`, `undeclared` or `ungoverned`
	file    string // the file; for `ungoverned`, the model's first file
	line    int
	column  int
	message string
}

// not_read is the problem of a file that could not be read, from its loading error: the place the
// parser names at the start of its message, when it names one.
fn not_read(path string, msg string) InputProblem {
	if msg.starts_with(path + ':') {
		head := msg.all_before(': ')
		l := parse_location(head)
		if l.file == path && l.line > 0 {
			return InputProblem{'not_read', path, l.line, l.column, msg}
		}
	}
	return InputProblem{
		kind:    'not_read'
		file:    path
		message: msg
	}
}

// Report is what a command found: its summary, the files it could not check and every finding.
pub struct Report {
pub:
	command    string   // the command that made it, `check`
	governing  string   // the schema (or rules file's schema) the model was merged by
	files      int      // files found
	loaded     int      // files read
	elements   int      // elements in the files read
	nodes      int      // nodes of the merged model
	merged     int      // of those, made of more than one element
	layers     []string // the layers that ran, in order
	took_ms    f64
	first_file string // the model's first file: where a finding on no file is placed
	inputs     []InputProblem
	findings   []Finding
}

// check_report is the report of check c of model m, whose schemas are sc.
pub fn check_report(m &Model, sc &Schemas, c &Checked) Report {
	mut inputs := m.failed.map(not_read(it.path, it.msg))
	mut ks := sc.undeclared.keys()
	ks.sort()
	for k in ks {
		inputs << InputProblem{
			kind:    'undeclared'
			file:    m.set.docs[k].path
			message: sc.undeclared[k]
		}
	}
	mut layers := []string{}
	for l in ['merge', 'xml_schema', 'multiplicity', 'reference'] {
		if l in c.times {
			layers << l
		}
	}
	mut took := f64(0)
	for _, t in c.times {
		took += f64(t.microseconds()) / 1000
	}
	return Report{
		command:    'check'
		governing:  c.governing
		files:      m.files.len
		loaded:     m.set.docs.len
		elements:   c.elements
		nodes:      c.view.len()
		merged:     c.merged
		layers:     layers
		took_ms:    took
		first_file: first_file(m)
		inputs:     inputs
		findings:   c.findings
	}
}

// input_report is check's report of model m where nothing could be checked, for why (no schema
// governs it): the files not read, and the model.
pub fn input_report(m &Model, why string) Report {
	mut inputs := m.failed.map(not_read(it.path, it.msg))
	inputs << InputProblem{
		kind:    'ungoverned'
		file:    first_file(m)
		message: why
	}
	return Report{
		command:    'check'
		files:      m.files.len
		loaded:     m.set.docs.len
		first_file: first_file(m)
		inputs:     inputs
	}
}

fn first_file(m &Model) string {
	return if m.set.docs.len > 0 { m.set.docs[0].path } else { '' }
}

// Tally is the findings of each severity.
pub struct Tally {
pub:
	errors   int
	warnings int
	ignored  int
}

// tally counts the findings by severity, in one pass.
pub fn (r &Report) tally() Tally {
	mut e, mut w, mut i := 0, 0, 0
	for f in r.findings {
		match f.severity {
			.error { e++ }
			.warning { w++ }
			.ignore { i++ }
		}
	}
	return Tally{e, w, i}
}

// failed reports whether the report fails its command: an error finding, or a file not checked.
pub fn (r &Report) failed() bool {
	return r.inputs.len > 0 || r.findings.any(it.severity == .error)
}

// format is the report in one of report_formats.
pub fn (r &Report) format(f string) string {
	return match f {
		'json' { r.json() }
		'sarif' { r.sarif() }
		else { r.junit() }
	}
}

// --- JSON --------------------------------------------------------------------------------------

// json is the report as arxmodel's JSON report (docs/report.md), one finding an element of
// `findings`, every severity included.
pub fn (r &Report) json() string {
	t := r.tally()
	mut b := strings.new_builder(4096 + r.findings.len * 256)
	b.write_string('{"version":${report_version},"tool":{"name":"arxmodel","version":${jstr(version)}},')
	b.write_string('"command":${jstr(r.command)},"governing":${jstr(r.governing)},')
	b.write_string('"summary":{"files":${r.files},"loaded":${r.loaded},"elements":${r.elements},')
	b.write_string('"nodes":${r.nodes},"merged":${r.merged},"layers":[${r.layers.map(jstr(it)).join(',')}],')
	b.write_string('"errors":${t.errors},"warnings":${t.warnings},"ignored":${t.ignored},')
	b.write_string('"inputs":${r.inputs.len},"took_ms":${r.took_ms:.1f}},')
	b.write_string('"inputs":[')
	for k, p in r.inputs {
		if k > 0 {
			b.write_u8(`,`)
		}
		b.write_string('{"kind":${jstr(p.kind)},"file":${jstr(p.file)},"line":${p.line},')
		b.write_string('"column":${p.column},"message":${jstr(p.message)}}')
	}
	b.write_string('],"findings":[')
	for k, f in r.findings {
		if k > 0 {
			b.write_u8(`,`)
		}
		b.write_string('{"layer":${jstr(f.layer.str())},"kind":${jstr(f.kind)},"rule":${jstr(rule_id(f))},')
		b.write_string('"severity":${jstr(f.severity.str())},"what":${jstr(f.what)},')
		b.write_string('"in_conflict":${f.in_conflict},"path":${jstr(f.path)},"message":${jstr(f.message)},')
		b.write_string('"locations":[')
		for j, at in f.at {
			if j > 0 {
				b.write_u8(`,`)
			}
			l := parse_location(at)
			b.write_string('{"file":${jstr(l.file)},"line":${l.line},"column":${l.column}}')
		}
		b.write_string(']}')
	}
	b.write_string(']}\n')
	return b.str()
}

// rule_id is a finding's rule: `layer.kind`.
fn rule_id(f Finding) string {
	return '${f.layer}.${f.kind}'
}

// jstr is s as a JSON string: its bytes as UTF-8, a sequence that is not UTF-8 replaced by U+FFFD.
fn jstr(s string) string {
	t := utf8_or_replaced(s)
	mut b := strings.new_builder(t.len + 2)
	b.write_u8(`"`)
	for c in t {
		match c {
			`"` { b.write_string('\\"') }
			`\\` { b.write_string('\\\\') }
			`\n` { b.write_string('\\n') }
			`\r` { b.write_string('\\r') }
			`\t` { b.write_string('\\t') }
			else {
				if c < 0x20 {
					b.write_string('\\u00${c:02x}')
				} else {
					b.write_u8(c)
				}
			}
		}
	}
	b.write_u8(`"`)
	return b.str()
}

// utf8_or_replaced is s with every byte that does not start a well-formed UTF-8 sequence (overlong,
// a surrogate, past U+10FFFF, cut short) replaced by U+FFFD; s itself where it is all UTF-8.
fn utf8_or_replaced(s string) string {
	mut i := 0
	for i < s.len {
		n := utf8_len_at(s, i)
		if n == 0 {
			break
		}
		i += n
	}
	if i == s.len {
		return s
	}
	mut b := strings.new_builder(s.len + 8)
	b.write_string(s[..i])
	for i < s.len {
		n := utf8_len_at(s, i)
		if n == 0 {
			b.write_string('�')
			i++
		} else {
			b.write_string(s[i..i + n])
			i += n
		}
	}
	return b.str()
}

// utf8_len_at is the length of the well-formed UTF-8 sequence at s[i], 0 where there is none.
fn utf8_len_at(s string, i int) int {
	c := s[i]
	if c < 0x80 {
		return 1
	}
	n, lo, hi := if c >= 0xC2 && c <= 0xDF {
		2, u8(0x80), u8(0xBF)
	} else if c == 0xE0 {
		3, u8(0xA0), u8(0xBF)
	} else if c == 0xED {
		3, u8(0x80), u8(0x9F)
	} else if c >= 0xE1 && c <= 0xEF {
		3, u8(0x80), u8(0xBF)
	} else if c == 0xF0 {
		4, u8(0x90), u8(0xBF)
	} else if c >= 0xF1 && c <= 0xF3 {
		4, u8(0x80), u8(0xBF)
	} else if c == 0xF4 {
		4, u8(0x80), u8(0x8F)
	} else {
		0, u8(0), u8(0)
	}
	if n == 0 || i + n > s.len || s[i + 1] < lo || s[i + 1] > hi {
		return 0
	}
	for k in 2 .. n {
		if s[i + k] < 0x80 || s[i + k] > 0xBF {
			return 0
		}
	}
	return n
}

// --- SARIF -------------------------------------------------------------------------------------

const sarif_schema = 'https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json'

// sarif is the report as SARIF 2.1.0: one result per error or warning finding (ignored ones are
// left out) and per input problem, its rule `layer.kind` (`input.not_read`, `input.undeclared`,
// `input.ungoverned`), its level from the severity. Every result has a physical location: one per
// place in the files, or the file it concerns (a finding on no file: the model's first file); the
// element's path is its logical location.
pub fn (r &Report) sarif() string {
	mut rules := []string{}
	mut index := map[string]int{}
	for p in r.inputs {
		id := 'input.${p.kind}'
		if id !in index {
			index[id] = rules.len
			rules << id
		}
	}
	for f in r.findings {
		if f.severity == .ignore {
			continue
		}
		id := rule_id(f)
		if id !in index {
			index[id] = rules.len
			rules << id
		}
	}
	mut b := strings.new_builder(4096 + r.findings.len * 384)
	b.write_string('{"\$schema":${jstr(sarif_schema)},"version":"2.1.0","runs":[{"tool":{"driver":{')
	b.write_string('"name":"arxmodel","version":${jstr(version)},"rules":[')
	for k, id in rules {
		if k > 0 {
			b.write_u8(`,`)
		}
		b.write_string('{"id":${jstr(id)},"name":${jstr(id)},"shortDescription":{"text":${jstr(id)}}}')
	}
	b.write_string(']}},"results":[')
	mut n := 0
	for p in r.inputs {
		if n > 0 {
			b.write_u8(`,`)
		}
		n++
		id := 'input.${p.kind}'
		b.write_string('{"ruleId":${jstr(id)},"ruleIndex":${index[id]},"level":"error",')
		b.write_string('"message":{"text":${jstr(p.message)}},"locations":[{')
		physical(mut b, Location{p.file, p.line, p.column})
		b.write_string('}]}')
	}
	for f in r.findings {
		if f.severity == .ignore {
			continue
		}
		if n > 0 {
			b.write_u8(`,`)
		}
		n++
		id := rule_id(f)
		level := if f.severity == .error { 'error' } else { 'warning' }
		b.write_string('{"ruleId":${jstr(id)},"ruleIndex":${index[id]},"level":"${level}",')
		b.write_string('"message":{"text":${jstr(f.message + ': ' + f.path)}},"locations":[')
		places := if f.at.len > 0 { f.at } else { [r.first_file] }
		for j, at in places {
			if j > 0 {
				b.write_u8(`,`)
			}
			b.write_u8(`{`)
			physical(mut b, parse_location(at))
			b.write_string(',"logicalLocations":[{"fullyQualifiedName":${jstr(f.path)}}]}')
		}
		b.write_string(']')
		if f.in_conflict {
			b.write_string(',"properties":{"in_conflict":true}')
		}
		b.write_u8(`}`)
	}
	b.write_string(']}]}\n')
	return b.str()
}

// physical writes l as a SARIF physicalLocation: the file, and its line and column where known.
fn physical(mut b strings.Builder, l Location) {
	b.write_string('"physicalLocation":{"artifactLocation":{"uri":${jstr(file_uri(l.file))}}')
	if l.line > 0 {
		b.write_string(',"region":{"startLine":${l.line}')
		if l.column > 0 {
			b.write_string(',"startColumn":${l.column}')
		}
		b.write_u8(`}`)
	}
	b.write_u8(`}`)
}

// file_uri is a file path as a URI reference: relative as it is, an absolute one as a `file:`
// URI (a UNC path `\\host\share\x` as `file://host/share/x`); separators as `/`, and the
// characters a URI reserves percent-encoded.
fn file_uri(path string) string {
	p := path.replace('\\', '/')
	mut b := strings.new_builder(p.len + 8)
	mut rest := p
	if p.starts_with('//') {
		b.write_string('file:')
	} else if p.starts_with('/') {
		b.write_string('file://')
	} else if p.len > 1 && p[1] == `:` && p[0].is_letter() {
		b.write_string('file:///${p[..2]}')
		rest = p[2..]
	}
	for c in rest {
		if c.is_letter() || c.is_digit() || c in [`/`, `-`, `.`, `_`, `~`] {
			b.write_u8(c)
		} else {
			b.write_string('%${c:02X}')
		}
	}
	return b.str()
}

// --- JUnit -------------------------------------------------------------------------------------

// junit is the report as JUnit XML: one test case per `layer.kind` found (and per kind of input
// problem), failing where any of its findings is an error, its warnings as standard output; one
// passing test case per layer that ran and found nothing. Ignored findings are left out.
pub fn (r &Report) junit() string {
	mut kinds := []string{}
	mut errs := map[string][]string{}
	mut warns := map[string][]string{}
	for p in r.inputs {
		id := 'input.${p.kind}'
		if id !in errs && id !in warns {
			kinds << id
		}
		errs[id] << '${p.file}: ${p.message}'
	}
	for f in r.findings {
		if f.severity == .ignore {
			continue
		}
		id := rule_id(f)
		if id !in errs && id !in warns {
			kinds << id
		}
		if f.severity == .error {
			errs[id] << f.str()
		} else {
			warns[id] << f.str()
		}
	}
	for l in r.layers {
		if !kinds.any(it.starts_with(l + '.')) {
			kinds << l
		}
	}
	mut failures := 0
	for k in kinds {
		if (errs[k] or { [] }).len > 0 {
			failures++
		}
	}
	mut b := strings.new_builder(4096 + r.findings.len * 256)
	b.write_string('<?xml version="1.0" encoding="UTF-8"?>\n')
	b.write_string('<testsuites name="arxmodel ${xattr(r.command)}" tests="${kinds.len}" failures="${failures}" time="${r.took_ms / 1000:.3f}">\n')
	b.write_string('  <testsuite name="arxmodel.${xattr(r.command)}" tests="${kinds.len}" failures="${failures}" errors="0" skipped="0">\n')
	for k in kinds {
		layer := k.all_before('.')
		b.write_string('    <testcase classname="arxmodel.${xattr(layer)}" name="${xattr(k)}"')
		e := errs[k] or { [] }
		w := warns[k] or { [] }
		if e.len == 0 && w.len == 0 {
			b.write_string('/>\n')
			continue
		}
		b.write_string('>\n')
		if e.len > 0 {
			b.write_string('      <failure type="error" message="${e.len} error${if e.len == 1 {
				''
			} else {
				's'
			}}">${xtext(e.join('\n'))}</failure>\n')
		}
		if w.len > 0 {
			b.write_string('      <system-out>${xtext(w.join('\n'))}</system-out>\n')
		}
		b.write_string('    </testcase>\n')
	}
	b.write_string('  </testsuite>\n</testsuites>\n')
	return b.str()
}

// xattr is s escaped for a double-quoted XML attribute value, by flatxml's escaper.
fn xattr(s string) string {
	return flatxml.escape_attr(xml_chars(s), `"`)
}

// xtext is s escaped for XML text, by flatxml's escaper.
fn xtext(s string) string {
	return flatxml.escape_text(xml_chars(s))
}

// xml_chars is s with what XML 1.0 cannot carry left out: control characters but tab, line feed
// and carriage return; and any sequence that is not UTF-8, replaced by U+FFFD.
fn xml_chars(s string) string {
	t := utf8_or_replaced(s)
	mut clean := true
	for c in t {
		if c < 0x20 && c != `\t` && c != `\n` && c != `\r` {
			clean = false
			break
		}
	}
	if clean {
		return t
	}
	return t.bytes().filter(it >= 0x20 || it in [`\t`, `\n`, `\r`]).bytestr()
}
