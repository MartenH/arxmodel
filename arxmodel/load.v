// arxmodel — AUTOSAR models (ARXML) read the way AUTOSAR tools see them: many files, one model.
//
// Loading reads every .arxml below the paths given into one flatxml document set, in parallel,
// namespaces resolved. Each file's declared schema is found in a directory the user gives and
// compiled once; its annotations are read into merge rules (rules.v).
module arxmodel

import flatxml
import os
import runtime
import time

// Model is the files of one load: the document set, and what could not be read.
@[heap]
pub struct Model {
pub mut:
	set    &flatxml.DocSet = unsafe { nil }
	failed []flatxml.LoadError
	files  []string // every file found, in the order loaded
	bytes  i64
	took   time.Duration
}

@[params]
pub struct LoadOptions {
pub:
	jobs int // threads; 0 for the default (`default_jobs`), at most 16
}

// Found is the .arxml files at some paths, and the directories that could not be read.
pub struct Found {
pub mut:
	files  []string
	failed []flatxml.LoadError
}

// find_arxml lists the .arxml files at the paths given: a file as itself, a directory as every
// file below it whose name ends in .arxml (any case), sorted so the order does not depend on
// the file system. A file reached twice (overlapping paths, two spellings of one directory) is
// listed once, where first reached. A path that does not exist is an error; a directory that
// cannot be read is listed as failed.
pub fn find_arxml(paths []string) !Found {
	mut f := Found{}
	mut seen := map[string]bool{}
	for p in paths {
		mut found := []string{}
		if os.is_dir(p) {
			collect_arxml(p, mut found, mut f.failed)
			found.sort()
		} else if os.exists(p) {
			found << p
		} else {
			return error('${p}: no such file or directory')
		}
		for file in found {
			real := os.real_path(file)
			if real !in seen {
				seen[real] = true
				f.files << file
			}
		}
	}
	return f
}

fn collect_arxml(dir string, mut out []string, mut failed []flatxml.LoadError) {
	names := os.ls(dir) or {
		failed << flatxml.LoadError{dir, '${dir}: ${err.msg()}'}
		return
	}
	for name in names {
		f := os.join_path(dir, name)
		if os.is_dir(f) && !os.is_link(f) {
			collect_arxml(f, mut out, mut failed)
		} else if name.to_lower().ends_with('.arxml') && os.is_file(f) {
			out << f
		}
	}
}

// default_jobs is the threads used for loading and for the XML schema layer where none are asked
// for: one per CPU, at most 8, so a run leaves room for what shares the machine with it.
pub fn default_jobs() int {
	n := runtime.nr_cpus()
	return if n > 8 {
		8
	} else if n < 1 {
		1
	} else {
		n
	}
}

// jobs_or_default is the threads asked for, or the default where none are.
fn jobs_or_default(asked int) int {
	return if asked > 0 { asked } else { default_jobs() }
}

// load reads every .arxml at the paths given into one document set. A file that fails to parse,
// or a directory that cannot be read, is listed in failed; the rest load all the same.
pub fn load(paths []string, opts LoadOptions) !&Model {
	found := find_arxml(paths)!
	sw := time.new_stopwatch()
	mut set := flatxml.DocSet.new()
	mut failed := found.failed.clone()
	failed << set.load(found.files, jobs: jobs_or_default(opts.jobs), namespaces: true)
	took := sw.elapsed()
	mut bytes := i64(0)
	for d in set.docs {
		bytes += d.src_len
	}
	return &Model{
		set:    set
		failed: failed
		files:  found.files
		bytes:  bytes
		took:   took
	}
}

// free releases the documents.
pub fn (mut m Model) free() {
	if m.set != unsafe { nil } {
		m.set.free()
	}
}

// element_count is the number of elements in all documents.
pub fn (m &Model) element_count() int {
	mut n := 0
	for d in m.set.docs {
		for i in 1 .. d.len() {
			if d.is_element(u32(i)) {
				n++
			}
		}
	}
	return n
}
