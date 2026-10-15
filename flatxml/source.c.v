module flatxml

import os

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// C's int is 32 bits; V3's int is 64, so C callbacks and returns are declared i32.
fn C.open(path &char, flags i32, mode i32) i32
fn C.close(fd i32) i32
fn C.madvise(addr voidptr, len usize, advice i32) i32
fn C.fchmod(fd i32, mode u32) i32
fn C.fsync(fd i32) i32

// Node and attribute offsets are stored as u32, so a document must be smaller than 4 GiB.
pub const max_src_len = int(u32(0xFFFF_FFFF))

// map_file maps the file at path read-only into memory.
fn map_file(path string) !(&u8, int) {
	if !os.is_file(path) {
		return error('${path}: not a file')
	}
	size := int(os.file_size(path))
	if size == 0 {
		return error('${path}: empty file')
	}
	if size > max_src_len {
		return error('${path}: files of 4 GiB or more are not supported (offsets are u32)')
	}
	fd := C.open(&char(path.str), C.O_RDONLY, 0)
	if fd < 0 {
		return error('${path}: cannot open file')
	}
	p := unsafe { C.mmap(nil, usize(size), C.PROT_READ, C.MAP_PRIVATE, fd, 0) }
	C.close(fd)
	if u64(p) == max_u64 { // MAP_FAILED
		return error('${path}: cannot map file')
	}
	// One forward pass reads the whole file; ask the kernel to read ahead.
	unsafe { C.madvise(p, usize(size), C.MADV_SEQUENTIAL) }
	return unsafe { &u8(p) }, size
}

fn unmap_file(p &u8, len int) {
	unsafe { C.munmap(voidptr(p), usize(len)) }
}

// FileOut is a file opened for writing, whose every write and close is checked.
struct FileOut {
	path string
mut:
	fd i32 = -1
}

// create_file creates path, which must not exist. With keep, it gets keep's permission bits (those
// of the file it will replace); without, the umask narrows them as for any new file.
fn create_file(path string, keep ?u32) !FileOut {
	fd := C.open(&char(path.str), C.O_WRONLY | C.O_CREAT | C.O_EXCL, 0o666)
	if fd < 0 {
		return error('${path}: cannot create file')
	}
	if mode := keep {
		C.fchmod(fd, mode & 0o7777)
	}
	return FileOut{
		path: path
		fd:   fd
	}
}

// write writes buf, at most 1 GiB per call.
fn (mut f FileOut) write(buf []u8) !int {
	n := C.write(f.fd, buf.data, usize(if buf.len > 1 << 30 { 1 << 30 } else { buf.len }))
	if n <= 0 {
		return error('${f.path}: write failed')
	}
	return int(n)
}

fn (mut f FileOut) close() ! {
	if f.fd >= 0 && C.close(f.fd) != 0 {
		f.fd = -1
		return error('${f.path}: write failed')
	}
	f.fd = -1
}

// sync_and_close puts the file's contents on disk, then closes it.
fn (mut f FileOut) sync_and_close() ! {
	if C.fsync(f.fd) != 0 {
		f.close() or {}
		return error('${f.path}: write failed')
	}
	f.close()!
}

// sync_dir puts a directory's entries on disk, so a file renamed into it stays renamed.
fn sync_dir(dir string) ! {
	fd := C.open(&char(dir.str), C.O_RDONLY | C.O_DIRECTORY, 0)
	if fd < 0 {
		return error('${dir}: cannot open directory to sync it')
	}
	r := C.fsync(fd)
	C.close(fd)
	if r != 0 {
		return error('${dir}: cannot sync directory')
	}
}
