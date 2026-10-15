module arxmodel

import flatxml.xsd
import os
import toml

// Filters: the policy's [[filter]] entries, each giving a severity to the findings it matches,
// after [severity]. A finding takes the first filter it matches; a filter that matches nothing in
// a run is itself a finding (policy.unused_filter).

// Filter is one [[filter]] of a policy: what it matches (every field given must match) and the
// severity it gives.
pub struct Filter {
pub:
	number     int    // its place in the policy, from 1
	on         string // `match`: a layer, `layer.kind` or `layer.kind:what`, as [severity] keys
	path       string // an AUTOSAR path glob: `*` one segment (or part of one), `**` any segments; an element with a key matched by its name unless the glob gives `[...]`
	file       string // a file glob, relative to the input roots or absolute
	message    string // a substring of the message
	message_re string // an XML Schema pattern the whole message matches
	base       string // a reference's BASE
	dest       string // a reference's DEST
	severity   Severity
	reason     string
mut:
	re       ?xsd.Pattern
	path_pat []string // path's segments, compiled once
	file_pat []string // file's segments, compiled once
	file_abs bool     // file is an absolute glob
}

// FilterField is one field of a [[filter]]: its name, the kind of value, and what it means.
pub struct FilterField {
pub:
	name        string
	enum_values []string // the values it takes, where it is a choice
	required    bool
	description string
}

// filter_fields are every field a [[filter]] takes: the one list the parser, the schema and
// `arxmodel policy` read.
pub fn filter_fields() []FilterField {
	return [
		FilterField{
			name:        'match'
			description: 'The findings of a layer, "layer.kind", or "layer.kind:element" ("layer.kind:@attribute"), as [severity] keys.'
		},
		FilterField{
			name:        'path'
			description: 'An AUTOSAR path glob: `*` matches one segment (or part of one), `**` any segments; `#` and the elements after it are segments too, an element with a key (NAME[key]) matched by its name unless the glob gives the key.'
		},
		FilterField{
			name:        'file'
			description: "A file glob (`*`, `**`, `?`) any of the finding's files matches: relative to the input roots, or absolute."
		},
		FilterField{
			name:        'message'
			description: 'A substring of the message.'
		},
		FilterField{
			name:        'message_re'
			description: 'An XML Schema pattern (XSD regular expressions: anchored at both ends, no back-references) the whole message matches.'
		},
		FilterField{
			name:        'base'
			description: "A reference finding's BASE attribute, as written."
		},
		FilterField{
			name:        'dest'
			description: "A reference finding's DEST attribute, as written."
		},
		FilterField{
			name:        'severity'
			enum_values: ['error', 'warning', 'ignore']
			required:    true
			description: 'The severity the matched findings take.'
		},
		FilterField{
			name:        'reason'
			description: 'Why: shown with the counts and in the JSON report. Recommended.'
		},
	]
}

// read_filters reads the [[filter]] array of a policy.
fn read_filters(v toml.Any) ![]Filter {
	if v !is []toml.Any {
		return error('policy: `filter` is an array of tables, [[filter]]')
	}
	fields := filter_fields()
	mut out := []Filter{}
	for k, item in v.array() {
		n := k + 1
		if item !is map[string]toml.Any {
			return error('policy: filter ${n} is not a table')
		}
		m := item.as_map()
		for key, _ in m {
			if !fields.any(it.name == key) {
				return error('policy: filter ${n}: unknown field `${key}`')
			}
		}
		mut text := map[string]string{}
		for key, x in m {
			if x !is string || x.string() == '' {
				return error('policy: filter ${n}: `${key}` takes a non-empty string, not ${show_value(x)}')
			}
			text[key] = x.string()
		}
		sev := text['severity'] or { return error('policy: filter ${n}: no `severity`') }
		severity := match sev {
			'error' { Severity.error }
			'warning' { Severity.warning }
			'ignore' { Severity.ignore }
			else {
				return error('policy: filter ${n}: `severity` takes one of "error", "warning", "ignore", not "${sev}"')
			}
		}
		if on := text['match'] {
			check_severity_key(on) or {
				return error('policy: filter ${n}: `match`: ${err.msg().all_after('policy: severity ')}')
			}
		}
		mut f := Filter{
			number:     n
			on:         text['match'] or { '' }
			path:       text['path'] or { '' }
			file:       text['file'] or { '' }
			message:    text['message'] or { '' }
			message_re: text['message_re'] or { '' }
			base:       text['base'] or { '' }
			dest:       text['dest'] or { '' }
			severity:   severity
			reason:     text['reason'] or { '' }
		}
		if f.message_re != '' {
			f.re = xsd.compile_pattern(f.message_re) or {
				return error('policy: filter ${n}: `message_re`: ${err.msg()}')
			}
		}
		f.path_pat = segments(f.path)
		f.file_pat = f.file.replace('\\', '/').split('/').filter(it != '')
		f.file_abs = os.is_abs_path(f.file)
		if text.len == 1 || (text.len == 2 && 'reason' in text) {
			return error('policy: filter ${n} matches every finding: give it a field to match')
		}
		out << f
	}
	return out
}

// toml is the filter as a TOML inline table, its fields in filter_fields' order.
pub fn (f &Filter) toml() string {
	mut parts := []string{}
	for name, v in {
		'match':      f.on
		'path':       f.path
		'file':       f.file
		'message':    f.message
		'message_re': f.message_re
		'base':       f.base
		'dest':       f.dest
		'severity':   '${f.severity}'
		'reason':     f.reason
	} {
		if v != '' {
			parts << '${name} = "${v.replace('\\', '\\\\').replace('"', '\\"')}"'
		}
	}
	return '{ ' + parts.join(', ') + ' }'
}

// segments are a path's segments for globbing: the names between `/`, with the `#` before the
// inner part a segment of its own, so `/Pkg/Name#ELEM/SUB[a/b]` is Pkg, Name, #, ELEM, SUB[a/b].
// Inside a key (`[...]`) nothing divides, and a key's own `[`, `]` and `\` are written escaped
// with `\` (as merged_path writes them).
fn segments(path string) []string {
	mut out := []string{}
	mut cur := []u8{}
	mut depth := 0
	mut inner := false
	mut escaped := false
	for c in path {
		if escaped {
			cur << c
			escaped = false
			continue
		}
		if c == `\\` {
			cur << c
			escaped = true
			continue
		}
		if c == `[` {
			depth++
		} else if c == `]` && depth > 0 {
			depth--
		}
		// `/` and the first `#` divide, outside a key
		if depth == 0 && (c == `/` || (c == `#` && !inner)) {
			if cur.len > 0 {
				out << cur.bytestr()
				cur.clear()
			}
			if c == `#` {
				out << '#'
				inner = true
			}
			continue
		}
		cur << c
	}
	if cur.len > 0 {
		out << cur.bytestr()
	}
	return out
}

// glob_segment reports whether a segment matches a segment pattern: `*` any characters, `?` one.
// A pattern with no key (`[...]`) matches a keyed segment by its element name. The `#` before the
// inner part is matched only by itself (or by `**`).
fn glob_segment(pat string, seg string) bool {
	if seg == '#' || pat == '#' {
		return pat == seg
	}
	s := if !pat.contains('[') && seg.contains('[') { seg.all_before('[') } else { seg }
	if pat == '*' {
		return true
	}
	if !pat.contains_any('*?') {
		return pat == s
	}
	// classic backtracking over one `*` at a time
	mut p, mut i := 0, 0
	mut star, mut mark := -1, 0
	for i < s.len {
		if p < pat.len && (pat[p] == `?` || pat[p] == s[i]) {
			p++
			i++
		} else if p < pat.len && pat[p] == `*` {
			star = p
			mark = i
			p++
		} else if star >= 0 {
			p = star + 1
			mark++
			i = mark
		} else {
			return false
		}
	}
	for p < pat.len && pat[p] == `*` {
		p++
	}
	return p == pat.len
}

// glob_segments reports whether segments match a pattern's segments, `**` matching any number.
fn glob_segments(pat []string, segs []string) bool {
	if pat.len == 0 {
		return segs.len == 0
	}
	if pat[0] == '**' {
		for k in 0 .. segs.len + 1 {
			if glob_segments(pat[1..], segs[k..]) {
				return true
			}
		}
		return false
	}
	if segs.len == 0 || !glob_segment(pat[0], segs[0]) {
		return false
	}
	return glob_segments(pat[1..], segs[1..])
}

// path_glob reports whether an AUTOSAR path (with its `#` part) matches a path glob.
pub fn path_glob(pattern string, path string) bool {
	return glob_segments(segments(pattern), segments(path))
}

// FileNames is a file as file globs read it, worked out once per file in a run: its segments as
// written, absolute, and relative to each root it lies under.
struct FileNames {
	written  []string
	absolute []string
	relative [][]string
}

// FilterRun is one application of a policy's filters: the roots, resolved once, and the files met.
struct FilterRun {
	roots []string // absolute, `/`-separated
mut:
	files map[string]FileNames
}

fn new_filter_run(roots []string) FilterRun {
	return FilterRun{
		roots: roots.map(os.abs_path(it).replace('\\', '/').trim_right('/'))
	}
}

fn (mut run FilterRun) names(file string) FileNames {
	if n := run.files[file] {
		return n
	}
	a := os.abs_path(file).replace('\\', '/')
	mut rel := [][]string{}
	for r in run.roots {
		if a == r {
			rel << [os.file_name(a)]
		} else if a.starts_with(r + '/') {
			rel << a[r.len + 1..].split('/').filter(it != '')
		}
	}
	n := FileNames{
		written:  file.replace('\\', '/').split('/').filter(it != '' && it != '.')
		absolute: a.split('/').filter(it != '')
		relative: rel
	}
	run.files[file] = n
	return n
}

// file_glob reports whether a file matches a file glob: an absolute glob against the file's
// absolute path, a relative one against the file as written or relative to any of the roots.
pub fn file_glob(pattern string, file string, roots []string) bool {
	mut run := new_filter_run(roots)
	pat := pattern.replace('\\', '/').split('/').filter(it != '')
	return run.file_matches(pat, os.is_abs_path(pattern), file)
}

fn (mut run FilterRun) file_matches(pat []string, abs bool, file string) bool {
	n := run.names(file)
	if abs {
		return glob_segments(pat, n.absolute)
	}
	if glob_segments(pat, n.written) {
		return true
	}
	return n.relative.any(glob_segments(pat, it))
}

// matches_kind reports whether a finding is of the layer, kind and what of a `match`:
// `merge.in_conflict` matches a merge finding on an element pair in conflict, whatever its kind,
// as [severity]'s `merge.in_conflict` does.
fn (f &Filter) matches_kind(x &Finding) bool {
	if f.on == '' {
		return true
	}
	if f.on.all_before('.').all_before(':') != '${x.layer}' {
		return false
	}
	if !f.on.contains('.') {
		return true
	}
	kind := f.on.all_after('.').all_before(':')
	if x.layer == .merge && kind == 'in_conflict' {
		if !x.in_conflict {
			return false
		}
	} else if kind != x.kind {
		return false
	}
	return !f.on.contains(':') || f.on.all_after(':') == x.what
}

// matches reports whether a finding matches every field the filter gives (file globs only where
// files is set).
fn (f &Filter) matches_in(mut run FilterRun, x &Finding, files bool) bool {
	if !f.matches_kind(x) {
		return false
	}
	if f.base != '' && f.base != x.base {
		return false
	}
	if f.dest != '' && f.dest != x.dest {
		return false
	}
	if f.message != '' && !x.message.contains(f.message) {
		return false
	}
	if re := f.re {
		if !re.matches(x.message) {
			return false
		}
	}
	if f.path != '' && !glob_segments(f.path_pat, segments(x.path)) {
		return false
	}
	if f.file != '' {
		if !files {
			return false
		}
		mut any := false
		for at in x.at {
			if run.file_matches(f.file_pat, f.file_abs, parse_location(at).file) {
				any = true
				break
			}
		}
		if !any {
			return false
		}
	}
	return true
}

// matches reports whether a finding matches every field the filter gives, relative file globs
// read from roots.
pub fn (f &Filter) matches(x &Finding, roots []string) bool {
	mut run := new_filter_run(roots)
	return f.matches_in(mut run, x, true)
}

// FilterOptions say how filters apply in one run.
pub struct FilterOptions {
pub:
	roots []string // the paths checked: relative file globs are read from them
	ran   []string // the layers that ran: a filter matching another layer is not reported unused
	// the result of a merge, checked in files that are not the input: file globs, written
	// against the input, are not applied there, and no filter is reported unused
	result bool
}

// apply_filters gives each finding the severity of the first filter it matches, and adds a
// finding for every filter that matched nothing: `policy.unused_filter`, itself filtered like any
// finding, except by the filter it reports (a filter does not use itself up by matching its own
// report). Not reported: a filter whose `match` names a layer that did not run, and every filter
// in a result check. Returns the findings and the count each filter matched.
pub fn apply_filters(findings []Finding, p Policy, opts FilterOptions) ([]Finding, []int) {
	if p.filters.len == 0 {
		return findings, []int{}
	}
	mut run := new_filter_run(opts.roots)
	files := !opts.result
	mut counts := []int{len: p.filters.len}
	mut out := []Finding{cap: findings.len + p.filters.len}
	for x in findings {
		out << run.filtered(x, p.filters, -1, files, mut counts)
	}
	if opts.result {
		return out, counts
	}
	// the unused filters' reports, filtered like findings: a filter matched only by reports is
	// used, and has no report of its own, so the set settles to a fixed point
	mut by_reports := []int{len: p.filters.len}
	mut reports := []Finding{}
	for _ in 0 .. p.filters.len + 1 {
		mut extra := []int{len: p.filters.len}
		reports = []Finding{}
		for k, f in p.filters {
			if counts[k] == 0 && by_reports[k] == 0 && layer_ran(f, opts.ran) {
				reports << run.filtered(unused_report(f, p), p.filters, k, files, mut extra)
			}
		}
		if extra == by_reports {
			break
		}
		by_reports = extra.clone()
	}
	for k in 0 .. counts.len {
		counts[k] += by_reports[k]
	}
	out << reports
	return out, counts
}

// layer_ran reports whether a filter's layer ran (any layer, for a filter that names none).
fn layer_ran(f &Filter, ran []string) bool {
	if f.on == '' || ran.len == 0 {
		return true
	}
	layer := f.on.all_before('.').all_before(':')
	return layer == 'policy' || layer in ran
}

// unused_report is the finding that a filter matched nothing.
fn unused_report(f &Filter, p Policy) Finding {
	why := if f.reason != '' { ' (${f.reason})' } else { '' }
	return Finding{
		layer:    .policy
		kind:     'unused_filter'
		what:     'filter ${f.number}'
		severity: p.severity(.policy, 'unused_filter', '')
		path:     '[[filter]] ${f.number}'
		message:  'filter ${f.number}${why} matched no finding'
	}
}

// filtered is a finding as the first filter that matches it (other than the filter numbered
// skip) leaves it, that filter's count raised.
fn (mut run FilterRun) filtered(x Finding, filters []Filter, skip int, files bool, mut counts []int) Finding {
	for k, f in filters {
		if k == skip {
			continue
		}
		if f.matches_in(mut run, &x, files) {
			counts[k]++
			return Finding{
				...x
				severity: f.severity
				filter:   f.number
				reason:   f.reason
				was:      x.severity
			}
		}
	}
	return x
}
