module arxmodel

import flatxml
import os

fn edata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

fn test_a_split_model_exports_as_one_document() {
	mut m := load([edata('export')])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, edata('schemas'))
	c := check(m, sc)!
	assert c.governing == 'LIB_2.xsd'
	assert c.findings.filter(it.severity == .error).len == 0
	dir := os.join_path(os.vtmp_dir(), 'arxmodel_export_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	out := os.join_path(dir, 'model.arxml')
	notes := export(c, m, sc, out)!
	// LIB_2.xsd is not a file beside b.arxml, so its text is kept, and said
	assert notes.len == 1 && notes[0].contains('no such file beside it')
	text := os.read_file(out)!
	// the first file's prolog and root, the governing schema's location
	assert text.starts_with('<?xml version="1.0" encoding="UTF-8"?>\n<!-- part of a model')
	assert text.contains('xsi:schemaLocation="urn:arxmodel:test:lib LIB_2.xsd"')
	assert !text.contains('LIB_1.xsd')
	// read alone, it is the merged model: valid against its schema, nothing to merge, the same
	// elements
	mut w := load([out])!
	defer {
		w.free()
	}
	wsc := compile_schemas(w, edata('schemas'))
	wc := check(w, wsc)!
	assert wc.governing == 'LIB_2.xsd'
	assert wc.findings.filter(it.severity == .error).len == 0, wc.findings.map(it.str()).join('\n')
	assert wc.merged == 0
	assert wc.view.len() == c.view.len()
	assert w.element_count() == c.view.len()
	for k in 0 .. c.view.len() {
		assert merged_path(wc.view.node(u32(k)), wc.index) == merged_path(c.view.node(u32(k)), c.index)
	}
	// Dune is one book; Analog, the theme and Poetry are there
	assert text.count('<SHORT-NAME>Dune</SHORT-NAME>') == 1
	assert text.contains('Analog') && text.contains('<THEME>space</THEME>') && text.contains('Poetry')
}

fn test_a_model_whose_first_file_declares_the_governing_schema_is_written_as_merged() {
	mut m := load([edata('export', 'a.arxml')])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, edata('schemas'))
	c := check(m, sc)!
	out := os.join_path(os.vtmp_dir(), 'arxmodel_export_one_${os.getpid()}.arxml')
	defer {
		os.rm(out) or {}
	}
	export(c, m, sc, out)!
	// one file whose children are in the order the rules give: written byte for byte
	assert os.read_file(out)! == os.read_file(edata('export', 'a.arxml'))!
}

fn test_a_model_merged_by_a_rules_file_names_the_release_of_its_rules() {
	mut m := load([edata('export')])!
	defer {
		m.free()
	}
	sc := declare_schemas(m)
	out := os.join_path(os.vtmp_dir(), 'arxmodel_export_rules_${os.getpid()}.arxml')
	defer {
		os.rm(out) or {}
	}
	// rules of LIB_1, which a.arxml declares, though b.arxml declares LIB_2
	mut one := load([edata('export', 'a.arxml')])!
	defer {
		one.free()
	}
	for rules_of, want in {
		'one':  'LIB_1.xsd'
		'both': 'LIB_2.xsd'
	} {
		flat, name := governing_flat(compile_schemas(if rules_of == 'one' { one } else { m },
			edata('schemas')))!
		assert name == want
		c := check_with(m, flat, name, default_policy().settings(), default_policy())!
		export(c, m, sc, out)!
		text := os.read_file(out)!
		assert text.contains('xsi:schemaLocation="urn:arxmodel:test:lib ${want}"')
		assert text.count('.xsd') == 1
	}
}

// export_files merges the files given by the schemas of testdata and exports the model to out.
fn export_files(dir string, files map[string]string, out string) ![]string {
	for name, text in files {
		path := os.join_path(dir, name)
		os.mkdir_all(os.dir(path))!
		os.write_file(path, text)!
	}
	mut m := load([dir])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, edata('schemas'))
	c := check(m, sc, skip_xml: true, skip_multiplicity: true)!
	return export(c, m, sc, out)!
}

const lib_ns = 'urn:arxmodel:test:lib'
const lib_root = '<LIBRARY xmlns="${lib_ns}" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

fn test_the_root_names_the_governing_schema_and_keeps_the_rest() {
	dir := os.join_path(os.vtmp_dir(), 'arxmodel_export_root_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	out := os.join_path(dir, 'out', 'model.arxml')
	os.mkdir_all(os.dir(out))!
	b := lib_root + ' xsi:schemaLocation="${lib_ns} LIB_2.xsd"/>'
	// the other pairs kept, the namespace's location replaced
	export_files(os.join_path(dir, 'pairs'), {
		'a.arxml': lib_root + ' xsi:schemaLocation="urn:other other.xsd ${lib_ns} LIB_1.xsd"/>'
		'b.arxml': b
	}, out)!
	assert os.read_file(out)!.contains('xsi:schemaLocation="urn:other other.xsd ${lib_ns} LIB_2.xsd"')
	// none in the first file, whose xsi is another namespace: one declared under a free prefix
	export_files(os.join_path(dir, 'prefix'), {
		'a.arxml': '<LIBRARY xmlns="${lib_ns}" xmlns:xsi="urn:not-xsi" xsi:t="1"/>'
		'b.arxml': b
	}, out)!
	text := os.read_file(out)!
	assert text.contains('xmlns:xsi="urn:not-xsi" xsi:t="1" xmlns:xsi1="http://www.w3.org/2001/XMLSchema-instance" xsi1:schemaLocation="${lib_ns} LIB_2.xsd"')
	mut d := flatxml.parse_string(text)!
	d.resolve_namespaces()!
	assert declared_schema(d).location == 'LIB_2.xsd'
	// a location relative to its file, which names a file there: relative to the output
	os.mkdir_all(os.join_path(dir, 'rel'))!
	os.write_file(os.join_path(dir, 'rel', 'LIB_2.xsd'), '')!
	notes := export_files(os.join_path(dir, 'rel'), {
		'a.arxml':     lib_root + ' xsi:schemaLocation="${lib_ns} LIB_1.xsd"/>'
		'sub/b.arxml': lib_root + ' xsi:schemaLocation="${lib_ns} ../LIB_2.xsd"/>'
	}, out)!
	assert notes.len == 0
	assert os.read_file(out)!.contains('xsi:schemaLocation="${lib_ns} ../rel/LIB_2.xsd"')
}

fn test_an_output_among_the_inputs_is_refused() {
	dir := os.join_path(os.vtmp_dir(), 'arxmodel_export_clash_${os.getpid()}')
	os.mkdir_all(os.join_path(dir, 'in'))!
	defer {
		os.rmdir_all(dir) or {}
	}
	file := os.join_path(dir, 'in', 'a.arxml')
	os.write_file(file, '')!
	assert output_clash(file, [file]) != none
	assert output_clash(os.join_path(dir, 'in', 'new.arxml'), [os.join_path(dir, 'in')]) != none
	assert output_clash(os.join_path(dir, 'in', '..', 'in', 'x.arxml'), [dir]) != none
	assert output_clash(os.join_path(dir, 'model.arxml'), [os.join_path(dir, 'in')]) == none
	assert output_clash(os.join_path(dir, 'in2.arxml'), [os.join_path(dir, 'in')]) == none
	assert output_clash('-', [dir]) == none
}
