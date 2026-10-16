module arxmodel

import os

fn C.GC_expand_hp(bytes usize) int

// grow_heap gives the collector, before a model of `bytes` is read, about the heap reading,
// merging and checking it will grow to: three times its bytes, at most half the memory
// available. Grown step by step instead, the collector marks everything held so far at every
// step, and on a large model that was a fifth of a check's time; reserved up front the steps
// are few. Only Boehm's collector has a heap to reserve; elsewhere it does nothing.
pub fn grow_heap(bytes u64) {
	mut want := bytes * 3
	if avail := mem_available() {
		if want > avail / 2 {
			want = avail / 2
		}
	}
	if want > 0 {
		C.GC_expand_hp(usize(want))
	}
}

// mem_available is MemAvailable from /proc/meminfo, in bytes, where there is one (Linux).
fn mem_available() ?u64 {
	text := os.read_file('/proc/meminfo') or { return none }
	for line in text.split_into_lines() {
		if line.starts_with('MemAvailable:') {
			return line.all_after(':').trim_space().all_before(' ').u64() * 1024
		}
	}
	return none
}
