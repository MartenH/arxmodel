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
