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
	assert found.files.map(os.file_name(it)) == ['a.arxml', 'bad.arxml', 'none.arxml', 'b.arxml',
		'c.ARXML']
	// sorted by path: the order of the arguments does not matter
	again := find_arxml([testdata('model', 'sub', '..', 'sub'), testdata('model'),
		testdata('model', 'sub', 'b.arxml')])!
	assert again.files == found.files
}

// a tree of files for the input set: in/one/x.arxml, in/one/deep/y.arxml, in/two/z.arxml,
// in/two/note.txt, in/empty/
fn input_tree() string {
	root := os.join_path(os.temp_dir(), 'arxmodel_inputs_${os.getpid()}', 'in')
	for d in ['one/deep', 'two', 'empty'] {
		os.mkdir_all(os.join_path(root, d)) or { panic(err) }
	}
	for f in ['one/x.arxml', 'one/deep/y.arxml', 'two/z.arxml', 'two/note.txt'] {
		os.write_file(os.join_path(root, f), '<R/>') or { panic(err) }
	}
	return root
}

fn rel_names(root string, f Found) []string {
	return f.files.map(it.all_after(root + os.path_separator).replace('\\', '/'))
}

fn test_globs_one_level_and_any_depth() {
	root := input_tree()
	// `*` within one name: in/*/*.arxml is each directory's own files
	one := find_arxml([os.join_path(root, '*', '*.arxml')])!
	assert rel_names(root, one) == ['one/x.arxml', 'two/z.arxml'] && one.warnings.len == 0
	// `**` any depth
	all := find_arxml([os.join_path(root, '**', '*.arxml')])!
	assert rel_names(root, all) == ['one/deep/y.arxml', 'one/x.arxml', 'two/z.arxml']
	// a glob matching a directory takes it whole
	dirs := find_arxml([os.join_path(root, 'o*')])!
	assert rel_names(root, dirs) == ['one/deep/y.arxml', 'one/x.arxml']
	// a glob matching nothing, and a directory with no .arxml file: warnings, not errors
	quiet := find_arxml([os.join_path(root, '*', '*.xml'), os.join_path(root, 'empty'),
		os.join_path(root, 'two')])!
	assert rel_names(root, quiet) == ['two/z.arxml']
	assert quiet.warnings.len == 2 && quiet.warnings[0].ends_with('*.xml: matches nothing')
		&& quiet.warnings[1].ends_with('empty: no .arxml file')
}

fn test_lists_and_excludes() {
	root := input_tree()
	list := os.join_path(root, 'gen', 'args.txt')
	os.mkdir_all(os.dir(list))!
	// relative to the list's own directory; comments and blank lines ignored; a list may list one
	os.write_file(list, '# the model\n\n../one\n  ../two/z.arxml  \n@more.txt\n')!
	os.write_file(os.join_path(root, 'gen', 'more.txt'), '../one/deep/y.arxml\n')!
	f := find_arxml(['@' + list])!
	assert rel_names(root, f) == ['one/deep/y.arxml', 'one/x.arxml', 'two/z.arxml']
	// excludes: a relative glob against the path as found, an absolute one against the absolute path
	ex := find_arxml(['@' + list], exclude: ['**/deep/**'])!
	assert rel_names(root, ex) == ['one/x.arxml', 'two/z.arxml']
	abs := find_arxml(['@' + list], exclude: [os.join_path(root, 'two', '*')])!
	assert rel_names(root, abs) == ['one/deep/y.arxml', 'one/x.arxml']
	// a list listing itself is refused; a list that cannot be read is an error
	os.write_file(os.join_path(root, 'gen', 'loop.txt'), '@loop.txt\n')!
	if _ := find_arxml(['@' + os.join_path(root, 'gen', 'loop.txt')]) {
		assert false
	}
	if _ := find_arxml(['@' + os.join_path(root, 'gen', 'nothing.txt')]) {
		assert false
	}
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

fn test_globs_take_arxml_files_unless_they_name_one() {
	root := input_tree()
	os.write_file(os.join_path(root, 'two', 'README.md'), 'x')!
	os.write_file(os.join_path(root, 'two', 'w.ARXML'), '<R/>')!
	// a wildcard name takes .arxml files only, the extension in any case
	any := find_arxml([os.join_path(root, 'two', '*')])!
	assert rel_names(root, any) == ['two/w.ARXML', 'two/z.arxml']
	low := find_arxml([os.join_path(root, 'two', '*.arxml')])!
	assert rel_names(root, low) == ['two/w.ARXML', 'two/z.arxml']
	// a glob naming its file explicitly takes it, whatever its extension
	named := find_arxml([os.join_path(root, '*', 'note.txt')])!
	assert rel_names(root, named) == ['two/note.txt']
	os.rm(os.join_path(root, 'two', 'w.ARXML'))!
}

fn test_a_glob_records_a_directory_it_cannot_read() {
	root := input_tree()
	locked := os.join_path(root, 'locked')
	os.mkdir_all(locked)!
	os.chmod(locked, 0)!
	defer {
		os.chmod(locked, 0o755) or {}
		os.rmdir_all(locked) or {}
	}
	if os.is_readable(locked) {
		return
	}
	f := find_arxml([os.join_path(root, '**', '*.arxml')])!
	assert f.failed.any(it.path == locked)
}

fn test_an_exclude_matches_any_spelling_of_a_file() {
	root := input_tree()
	// one file by two spellings: the exclude names the second
	f := find_arxml([os.join_path(root, 'one'), os.join_path(root, 'two', '..', 'one', 'x.arxml')],
		exclude: ['**/two/../one/x.arxml']
	)!
	assert !f.files.any(it.ends_with('x.arxml'))
}

fn test_the_set_knows_where_its_files_came_from() {
	root := input_tree()
	list := os.join_path(root, 'gen', 'bases.txt')
	os.mkdir_all(os.dir(list))!
	os.write_file(list, '../one\n../two/*.arxml\n')!
	f := find_arxml(['@' + list])!
	assert f.bases == [os.join_path(root, 'gen'), os.join_path(root, 'one'), os.join_path(root, 'two')]
	// so a merge cannot write into a directory read through a list
	inputs := f.files.clone()
	mut all := inputs.clone()
	all << f.bases
	assert output_clash(os.join_path(root, 'one', 'out.arxml'), all) != none
	assert output_clash(f.files[0], all) != none
	assert output_clash(os.join_path(root, 'elsewhere.arxml'), all) == none
}

fn test_a_file_is_itself_whatever_its_name_holds() {
	dir := os.join_path(os.temp_dir(), 'arxmodel_literal_${os.getpid()}')
	os.mkdir_all(os.join_path(dir, 'more')) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	odd := os.join_path(dir, 'body*.arxml')
	os.write_file(odd, '<AUTOSAR/>')!
	os.write_file(os.join_path(dir, 'bodyX.arxml'), '<AUTOSAR/>')!
	os.write_file(os.join_path(dir, 'more', 'm.arxml'), '<AUTOSAR/>')!
	// alone, or beside a directory: the file, not a glob over its neighbours
	assert find_arxml([odd], LoadOptions{})!.files == [odd]
	both := find_arxml([odd, os.join_path(dir, 'more')], LoadOptions{})!
	assert both.files.map(os.file_name(it)) == ['body*.arxml', 'm.arxml']
	// and excluded or named twice as any file is
	assert find_arxml([odd], exclude: [odd])!.files == []
	assert find_arxml([odd, os.join_path(dir, '.', 'body*.arxml')], LoadOptions{})!.files == [odd]
}

fn test_the_lists_read_are_reported() {
	dir := os.join_path(os.temp_dir(), 'arxmodel_lists_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'a.arxml'), '<AUTOSAR/>')!
	os.write_file(os.join_path(dir, 'inner.txt'), 'a.arxml\n')!
	os.write_file(os.join_path(dir, 'outer.txt'), '@inner.txt\n')!
	f := find_arxml(['@' + os.join_path(dir, 'outer.txt')], LoadOptions{})!
	assert f.files.map(os.file_name(it)) == ['a.arxml']
	assert f.lists.map(os.file_name(it)) == ['outer.txt', 'inner.txt']
	// a list's relative `@x` entry that is a file, read from the list's directory: that file
	os.write_file(os.join_path(dir, '@notes.arxml'), '<AUTOSAR/>')!
	os.write_file(os.join_path(dir, 'with_at.txt'), '@notes.arxml\n')!
	g := find_arxml(['@' + os.join_path(dir, 'with_at.txt')], LoadOptions{})!
	assert g.files.map(os.file_name(it)) == ['@notes.arxml']
}

fn test_a_unc_glob_keeps_its_share() {
	base, rest := glob_base('\\\\server\\share\\models\\*.arxml')
	assert base == '//server/share/models'
	assert rest == ['*.arxml']
}

fn test_an_unreadable_configuration_is_an_error() {
	$if windows {
		return
	}
	if os.getuid() == 0 {
		return // root reads it anyway
	}
	dir := os.join_path(os.temp_dir(), 'arxmodel_cfg_${os.getpid()}')
	os.mkdir_all(os.join_path(dir, 'arxmodel')) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	cfg := os.join_path(dir, 'arxmodel', 'config.toml')
	os.write_file(cfg, 'schema_dir = "x"\n')!
	os.chmod(cfg, 0o000)!
	old_env, old_xdg := os.getenv('ARXMODEL_SCHEMA_DIR'), os.getenv('XDG_CONFIG_HOME')
	os.setenv('ARXMODEL_SCHEMA_DIR', '', true)
	os.setenv('XDG_CONFIG_HOME', dir, true)
	defer {
		os.setenv('ARXMODEL_SCHEMA_DIR', old_env, true)
		os.setenv('XDG_CONFIG_HOME', old_xdg, true)
		os.chmod(cfg, 0o600) or {}
	}
	configured_schema_dir() or {
		assert err.msg().contains('config.toml'), err.msg()
		// and one below a directory that cannot be searched is not absent either
		os.chmod(cfg, 0o600)!
		os.chmod(os.join_path(dir, 'arxmodel'), 0o000)!
		configured_schema_dir() or {
			os.chmod(os.join_path(dir, 'arxmodel'), 0o755) or {}
			assert err.msg().contains('config.toml'), err.msg()
			return
		}
		os.chmod(os.join_path(dir, 'arxmodel'), 0o755) or {}
		assert false, 'a configuration that cannot be reached read as none'
		return
	}
	assert false, 'an unreadable configuration read as none'
}
