module arxmodel

import os

fn src(path string, body string) Source {
	return Source{path, body.bytes()}
}

const open_a = '<AUTOSAR xmlns="urn:m"><AR-PACKAGES><AR-PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>' +
	'<THING><SHORT-NAME>A</SHORT-NAME><OTHER-REF DEST="THING">/P/B</OTHER-REF></THING>' +
	'</ELEMENTS></AR-PACKAGE></AR-PACKAGES></AUTOSAR>'

// the same package in a second file, the namespace bound to a prefix
const open_b = '<ar:AUTOSAR xmlns:ar="urn:m"><ar:AR-PACKAGES><ar:AR-PACKAGE><ar:SHORT-NAME>P</ar:SHORT-NAME><ar:ELEMENTS>' +
	'<ar:THING><ar:SHORT-NAME>B</ar:SHORT-NAME><ar:OTHER-REF DEST="THING" BASE="x">B</ar:OTHER-REF>' +
	'<ar:GONE-REF DEST="THING">/P/C</ar:GONE-REF></ar:THING>' +
	'</ar:ELEMENTS></ar:AR-PACKAGE></ar:AR-PACKAGES></ar:AUTOSAR>'

fn test_open_indexes_a_model_split_over_files() {
	mut o := open_sources([src('a.arxml', open_a), src('b.arxml', open_b)])!
	defer {
		o.free()
	}
	a := o.at('/P/A')
	b := o.at('/P/B')
	assert a.ok() && b.ok()
	assert o.path_of(b) == '/P/B'
	assert b.local_name() == 'THING'
	// one package, from both files
	assert o.at('/P').fragment_count() == 2
	assert o.of_kind('THING').map(o.path_of(it)) == ['/P/A', '/P/B']
	assert o.of_kind('AR-PACKAGE').len == 1
	assert o.of_kind('NOTHING').len == 0
	assert !o.at('/P/C').ok()
	assert o.pos(b).starts_with('b.arxml:1:')
}

fn test_open_follows_absolute_references_only() {
	mut o := open_sources([src('a.arxml', open_a), src('b.arxml', open_b)])!
	defer {
		o.free()
	}
	mut refs := map[string]string{}
	for t in o.of_kind('THING') {
		for c in t.children() {
			if c.local_name().ends_with('-REF') {
				refs['${o.path_of(t)} ${c.local_name()}'] = if n := o.target(c) {
					o.path_of(n)
				} else {
					'none'
				}
			}
		}
	}
	assert refs == {
		'/P/A OTHER-REF': '/P/B'
		'/P/B OTHER-REF': 'none' // relative, with BASE
		'/P/B GONE-REF':  'none' // dangling
	}
}

fn test_open_refuses_a_document_that_does_not_parse() {
	open_sources([src('bad.arxml', '<AUTOSAR>')]) or {
		assert err.msg().contains('bad.arxml')
		return
	}
	assert false
}

fn test_open_keeps_the_order_written_and_lists_what_one_file_repeats() {
	text := '<AUTOSAR xmlns="urn:m"><AR-PACKAGES><AR-PACKAGE><SHORT-NAME>P</SHORT-NAME><ELEMENTS>' +
		'<THING><SHORT-NAME>Z</SHORT-NAME></THING><THING><SHORT-NAME>A</SHORT-NAME></THING>' +
		'<THING><SHORT-NAME>Z</SHORT-NAME><V>1</V></THING></ELEMENTS></AR-PACKAGE></AR-PACKAGES></AUTOSAR>'
	mut o := open_sources([src('a.arxml', text)])!
	defer {
		o.free()
	}
	assert o.of_kind('THING').map(o.path_of(it)) == ['/P/Z', '/P/A']
	assert o.repeated.len == 1
	assert o.repeated[0].starts_with('/P/Z: a.arxml:1:')
	assert o.repeated[0].contains(', a.arxml:1:')
}

fn test_a_model_file_reads_its_paths_from_its_own_directory() {
	dir := os.join_path(os.temp_dir(), 'arxmodel_modelfile_${os.getpid()}')
	os.mkdir_all(os.join_path(dir, 'part')) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'part', 'a.arxml'), open_a)!
	os.write_file(os.join_path(dir, 'b.arxml'), open_b)!
	os.write_file(os.join_path(dir, 'old.arxml'), '<broken')!
	mf_path := os.join_path(dir, 'sys.arxmodel.toml')
	os.write_file(mf_path, 'paths = ["part/", "*.arxml"]\nexclude = ["old.arxml"]\n')!
	assert is_model_file(mf_path)
	mf := load_model_file(mf_path)!
	assert mf.paths == [os.join_path(dir, 'part/'), os.join_path(dir, '*.arxml')]
	mut o := open(mf.paths, OpenOptions{
		exclude: mf.exclude
	})!
	defer {
		o.free()
	}
	assert o.model.failed.len == 0
	assert o.model.files.len == 2
	assert o.rules == 'built-in identity rules'
	assert o.of_kind('THING').map(o.path_of(it)) == ['/P/B', '/P/A'] // sorted by path: b.arxml, part/a.arxml
}

fn test_a_model_file_refuses_what_it_does_not_know() {
	for text, want in {
		'':                                          '`paths` names no file'
		'paths = ["a"]\nschema = "x"':               'unknown setting `schema`'
		'paths = "a"':                               '`paths` takes a list of strings'
		'paths = ["a"]\nschema_dir = "d"\nrules = "r"': 'both given'
	} {
		parse_model_file(text, 'm.arxmodel.toml') or {
			assert err.msg().contains(want), err.msg()
			continue
		}
		assert false, text
	}
}

fn test_open_by_a_schema_dir_that_governs_nothing_is_an_error() {
	open_sources([src('a.arxml', open_a)], schema_dir: os.temp_dir()) or {
		assert err.msg().contains('no schema governs') || err.msg().contains('namespace'), err.msg()
		return
	}
	assert false
}

fn test_open_by_the_schema_the_files_declare() {
	files := [os.join_path(@VMODROOT, 'testdata', 'model', 'a.arxml'),
		os.join_path(@VMODROOT, 'testdata', 'model', 'sub', 'b.arxml')]
	mut o := open(files, schema_dir: os.join_path(@VMODROOT, 'testdata', 'schemas'))!
	defer {
		o.free()
	}
	assert o.rules == 'schema LIB_1.xsd'
	// one shelf, from both files, its items as first written
	assert o.at('/Fiction').fragment_count() == 2
	assert o.of_kind('BOOK').map(o.path_of(it)) == ['/Fiction/Dune']
	assert o.of_kind('MAGAZINE').map(o.path_of(it)) == ['/Fiction/Analog']
}
