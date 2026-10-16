module arxmodel

import os

// The generated texts ARE the files they were made from: change one and forget
// scripts/gen_builtin.vsh, and this fails rather than the library carrying the old text.
fn test_the_builtin_texts_are_the_files() {
	for path, text in builtin_files {
		assert text == os.read_file(os.join_path(@VMODROOT, path))!, '${path} changed: v run scripts/gen_builtin.vsh'
	}
}
