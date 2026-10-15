module arxmodel

import os

fn testdata(p ...string) string {
	mut parts := ['testdata']
	parts << p
	return os.join_path(@VMODROOT, ...parts)
}

fn test_find_arxml_walks_directories_in_order() {
	found := find_arxml([testdata('model')])!
	assert found.files.map(os.file_name(it)) == ['a.arxml', 'bad.arxml', 'none.arxml', 'b.arxml',
		'c.ARXML']
	assert found.failed.len == 0
	if _ := find_arxml([testdata('nowhere')]) {
		assert false
	}
}

fn test_find_arxml_lists_a_file_once() {
	found := find_arxml([testdata('model', 'sub', 'b.arxml'), testdata('model'),
		testdata('model', 'sub', '..', 'sub')])!
	assert found.files.map(os.file_name(it)) == ['b.arxml', 'a.arxml', 'bad.arxml', 'none.arxml',
		'c.ARXML']
}

fn test_unreadable_directory_is_a_failure() {
	dir := os.join_path(os.temp_dir(), 'arxmodel_unreadable_${os.getpid()}')
	locked := os.join_path(dir, 'locked')
	os.mkdir_all(locked)!
	os.write_file(os.join_path(dir, 'x.arxml'), '<R/>')!
	os.chmod(locked, 0)!
	defer {
		os.chmod(locked, 0o755) or {}
		os.rmdir_all(dir) or {}
	}
	if os.is_readable(locked) {
		// running as a user no permission stops (root): nothing to test
		return
	}
	mut m := load([dir])!
	defer {
		m.free()
	}
	assert m.set.docs.len == 1
	assert m.failed.len == 1
	assert m.failed[0].path == locked
}

fn test_load_reports_files_that_fail() {
	mut m := load([testdata('model')])!
	defer {
		m.free()
	}
	assert m.files.len == 5
	assert m.set.docs.len == 4
	assert m.failed.len == 1
	assert m.failed[0].path.ends_with('bad.arxml')
	assert m.element_count() > 0
}

fn test_declared_schemas_found_and_compiled_once() {
	mut m := load([testdata('model')])!
	defer {
		m.free()
	}
	sc := compile_schemas(m, testdata('schemas'))
	assert sc.uses.len == 2
	lib := sc.uses[0]
	assert lib.name == 'LIB_1.xsd' && lib.ns == 'urn:arxmodel:test:lib'
	assert lib.docs.len == 2
	assert lib.path.ends_with(os.join_path('LIB_1', 'LIB_1.xsd'))
	assert lib.error == ''
	assert lib.rules.rules.len > 0
	missing := sc.uses[1]
	assert missing.name == 'MISSING_9.xsd' && missing.docs.len == 1
	assert missing.error.starts_with('not found')
	assert sc.undeclared.len == 1
	assert sc.undeclared.values() == ['no xsi:schemaLocation']
}

fn test_find_schema_ignoring_case_says_so() {
	path, note := find_schema(testdata('schemas'), 'lib_1.xsd')
	assert path.ends_with('LIB_1.xsd')
	assert note.contains('differs in case')
	p2, _ := find_schema(testdata('schemas'), 'LIB_1.xsd')
	assert p2.ends_with('LIB_1.xsd')
}
