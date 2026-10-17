module main

import arxmodel
import net
import net.unix
import os
import strings
import time

// A model kept loaded, answering the commands that read one (values, get, list) over a Unix
// domain socket. `arxmodel serve --socket PATH <file|dir>...` reads and merges the files once;
// `arxmodel values --socket PATH PATTERN` (and get, list) asks it and prints what the command
// would print, with its exit code. Before each answer the server finds its input set again and
// looks at each file's size, inode and modification time: anything different (a file added,
// removed or written) and it reads the files again first, so an answer is never from files that
// have changed. Modification times have one-second resolution: a file written in the second its
// files were read is taken as changed until that second has passed (git's racy-file rule), and
// `--reload` reads them again whatever. The model lives in a worker process the server starts
// again for each reading (Worker), so the server holds one model's memory however often the files
// change; files that cannot be read just then (a tool writing them) give an answer saying so,
// exit 2, and the next request tries again.
//
// One request a connection, one connection at a time:
//
//   request   COMMAND <tab> ARGUMENT <newline>   (values, get, list, reload, ping, stop)
//   answer    CODE <space> OUTLEN <space> ERRLEN <newline>, then OUTLEN bytes of standard
//             output and ERRLEN bytes of standard error, as the command would print them

// Answer is what a command prints and its exit code.
struct Answer {
	out  string
	err  string
	code int
}

// emit prints an answer as the command does, and exits with its code.
@[noreturn]
fn (a Answer) emit() {
	print(a.out)
	eprint(a.err)
	flush_stdout()
	flush_stderr()
	exit(a.code)
}

// values_pattern_error is why a pattern is none, or none.
fn values_pattern_error(pattern string) ?string {
	if (!pattern.starts_with('/') && !pattern.starts_with('#') && !pattern.starts_with('**'))
		|| (pattern != '/' && os.exists(pattern)) {
		return 'values: ${pattern} is no path pattern (/Pkg/Name, /Pkg/**/Name, ...): the pattern comes before the files'
	}
	return none
}

// answer_values is every value a path pattern wants, one a line: `path = "text"`.
fn answer_values(c &arxmodel.Checked, pattern string) Answer {
	vals := c.values(pattern)
	mut sb := strings.new_builder(vals.len * 64 + 16)
	for v in vals {
		sb.writeln(v.line())
	}
	return Answer{
		out:  sb.str()
		err:  '${plural(vals.len, 'value')}\n'
		code: if vals.len == 0 { 1 } else { 0 }
	}
}

// answer_get is the merged element at an AUTOSAR path: its element, and each file and line it is
// made of.
fn answer_get(c &arxmodel.Checked, path string) Answer {
	hs := c.index.holders(path)
	if hs.len == 0 {
		return Answer{
			err:  'nothing at ${path}\n'
			code: 1
		}
	}
	mut sb := strings.new_builder(256)
	if hs.len > 1 {
		sb.writeln('${path}: held by ${hs.len} elements, which the merge keeps apart')
	}
	mut v := c.view
	for k in hs {
		n := v.node(k)
		sb.writeln('${c.index.path_of(k) or { '' }}: ${n.name()}, ${plural(n.fragment_count(), 'element')}, ${n.child_count()} below it')
		for f in n.fragments() {
			sb.writeln('  ${v.pos(f)}')
		}
	}
	return Answer{
		out: sb.str()
	}
}

// answer_list is the AUTOSAR path of every referrable element of one element name, a path held by
// two such elements once for each.
fn answer_list(c &arxmodel.Checked, kind string) Answer {
	paths := list_paths(c, kind)
	mut sb := strings.new_builder(paths.len * 64 + 16)
	for p in paths {
		sb.writeln(p)
	}
	return Answer{
		out: sb.str()
		err: '${plural(paths.len, kind)}\n'
	}
}

// list_paths are the AUTOSAR paths of every referrable element of one element name, sorted.
fn list_paths(c &arxmodel.Checked, kind string) []string {
	mut paths := []string{}
	for j, n in c.index.nodes {
		if c.view.node(n).name() == kind {
			paths << c.index.path_at(j)
		}
	}
	paths.sort()
	return paths
}

// ask asks the server at socket for a command's answer.
fn ask(socket string, cmd string, arg string) Answer {
	mut conn := unix.connect_stream(socket) or {
		return Answer{
			err:  'no server at ${socket} (${err.msg()}): start one with `arxmodel serve --socket ${socket} <file|dir>...`\n'
			code: 2
		}
	}
	defer {
		conn.close() or {}
	}
	// the answer may wait for the files to be read again
	conn.set_read_timeout(30 * time.minute)
	conn.write_string('${cmd}\t${arg}\n') or {
		return Answer{
			err:  '${socket}: ${err.msg()}\n'
			code: 2
		}
	}
	data := read_all(mut conn)
	nl := data.index(`\n`)
	head := if nl < 0 { []string{} } else { data[..nl].bytestr().split(' ') }
	if head.len != 3 || data.len != nl + 1 + head[1].int() + head[2].int() {
		return Answer{
			err:  '${socket}: no answer, or a cut one\n'
			code: 2
		}
	}
	out_end := nl + 1 + head[1].int()
	return Answer{
		out:  data[nl + 1..out_end].bytestr()
		err:  data[out_end..].bytestr()
		code: head[0].int()
	}
}

// read_all reads a connection to its end.
fn read_all(mut conn unix.StreamConn) []u8 {
	mut out := []u8{}
	mut buf := []u8{len: 64 * 1024}
	for {
		n := conn.read(mut buf) or { break }
		if n <= 0 {
			break
		}
		out << buf[..n]
	}
	return out
}

// read_request reads one request line, waiting for it at most request_timeout: a client that
// connects and says nothing holds no server up ('' then).
fn read_request(mut conn unix.StreamConn) string {
	deadline := time.now().add(request_timeout)
	mut got := []u8{}
	mut buf := []u8{len: 4096}
	for got.len < 1024 * 1024 && got.index(`\n`) < 0 {
		// one deadline for the whole request, not one a read: a client sending a byte at a time
		// holds no one up either. The socket blocks: wait for data within what is left first.
		left := deadline - time.now()
		if left <= 0 {
			break
		}
		conn.set_read_timeout(left)
		conn.wait_for_read() or { break }
		n := conn.read(mut buf) or { break }
		if n <= 0 {
			break
		}
		got << buf[..n]
	}
	if got.index(`\n`) < 0 {
		return ''
	}
	return got.bytestr().all_before('\n')
}

const request_timeout = 5 * time.second

// answer_timeout is how long an answer is written for: arxmodel reads an answer whole before it
// prints it, so only a client that does not read takes it.
const answer_timeout = 10 * time.second

// is_socket reports whether path is a socket: only a socket left behind is removed, never a file
// a mistyped --socket names.
fn is_socket(path string) bool {
	st := os.stat(path) or { return false }
	return st.get_filetype() == .socket
}

fn C.umask(mask u32) u32

// listen_private listens at a socket only its owner can use: made so (umask) and kept so (chmod),
// or refused. Not on Windows, where a socket takes its directory's access list, which may let
// others in: serve is not offered there.
fn listen_private(socket string) !&unix.StreamListener {
	$if !windows {
		old := C.umask(0o177)
		mut l := unix.listen_stream(socket) or {
			C.umask(old)
			return err
		}
		C.umask(old)
		os.chmod(socket, 0o600) or {
			l.close() or {}
			return error('${socket}: not made readable by its owner alone: ${err.msg()}')
		}
		return l
	} $else {
		return error('serve is not offered on Windows: a socket there is not made its owner alone')
	}
}

// send writes an answer within one deadline (answer_timeout), the socket made not to block so the
// deadline holds: a client that asks and does not read holds no one up.
fn send(mut conn unix.StreamConn, a Answer) {
	net.set_blocking(conn.sock.handle, false) or {}
	conn.set_write_timeout(0)
	conn.set_write_deadline(time.now().add(answer_timeout))
	conn.write_string('${a.code} ${a.out.len} ${a.err.len}\n${a.out}${a.err}') or {}
}

// Stamp is one file of the input set as it was found: its size, inode and modification time.
struct Stamp {
	path  string
	size  u64
	inode u64
	mtime i64
	ctime i64 // a status change: permissions (a file made unreadable), links
	mode  u32
}

// stamps are the files of the input set, found again, and how they are now.
fn stamps(o Opts) []Stamp {
	// the set not found at all (a path gone, a list unreadable) is a stamp of its own: a change
	// from any set found, and from an empty one
	found := arxmodel.find_arxml(o.paths, exclude: o.exclude) or {
		return [Stamp{
			path:  'not found: ${err.msg()}'
			mtime: -1
		}]
	}
	mut out := []Stamp{cap: found.files.len + found.failed.len}
	// a directory that cannot be read (now, or no more) is as much a change as a file
	for f in found.failed {
		out << Stamp{
			path:  'not read: ${f.msg}'
			mtime: -1
		}
	}
	for f in found.files {
		st := os.stat(f) or {
			out << Stamp{
				path:  f
				mtime: -1
			}
			continue
		}
		out << Stamp{
			path:  f
			size:  st.size
			inode: st.inode
			mtime: st.mtime
			ctime: st.ctime
			mode:  st.mode
		}
	}
	return out
}

// changed is how many files differ between two looks at the input set (added, removed, written),
// a file written in the second the model was read counting as written.
fn changed(was []Stamp, now []Stamp, read_at i64) int {
	mut n := 0
	mut before := map[string]Stamp{}
	for s in was {
		before[s.path] = s
	}
	for s in now {
		b := before[s.path] or {
			n++
			continue
		}
		// written in the second the files were read in (not any later time: a file dated ahead by
		// another clock would read as changed until this one caught up)
		if b != s || s.mtime == read_at {
			n++
		}
		before.delete(s.path)
	}
	return n + before.len
}

// Worker is the process holding the model: `arxmodel serve --worker` at a socket of its own,
// started again when the files change, so the server's memory is one model's whatever how often
// they are read (a process's memory goes back to the system with it), and a worker that fails
// takes no server down.
struct Worker {
mut:
	p       &os.Process = unsafe { nil }
	socket  string
	stamp   []Stamp
	read_at i64
	files   int
}

// worker_args are the server's own arguments for a worker: what it reads and how, at socket.
fn worker_args(o Opts, socket string) []string {
	mut out := ['serve', '--worker', '--socket', socket]
	// the rules as resolved when the server started, whatever the configuration says later
	if o.builtin {
		out << '--no-schema'
	} else if o.rules_file != '' {
		out << ['--rules', os.real_path(o.rules_file)]
	} else if o.schema_dir != '' {
		out << ['--schema-dir', os.real_path(o.schema_dir)]
	}
	mut k := 2
	for k < os.args.len {
		a := os.args[k]
		if a in ['--socket', '--idle', '--schema-dir', '--rules'] {
			k += 2
			continue
		}
		if a !in ['--reload', '--stop', '--no-schema'] {
			out << a
		}
		k++
	}
	return out
}

// start_worker starts a worker on the input set as it is now and waits until it answers.
fn start_worker(o Opts, socket string) !Worker {
	mut stamp := stamps(o)
	mut read_at := time.now().unix()
	// a file written in this second may be written again in it, to the same size and times: read
	// in the next second, so that a file dated the second the model was read is one written after
	if stamp.any(it.mtime == read_at) {
		time.sleep(time.Duration((read_at + 1) * 1000 - time.now().unix_milli() + 1) * time.millisecond)
		stamp = stamps(o)
		read_at = time.now().unix()
	}
	if os.exists(socket) {
		if !is_socket(socket) {
			return error('${socket} is there and is no socket: not removed')
		}
		os.rm(socket) or {}
	}
	mut p := os.new_process(os.executable())
	p.set_args(worker_args(o, socket))
	p.run()
	for {
		if !p.is_alive() {
			p.wait()
			code := p.code
			p.close()
			why := os.read_file('${socket}.err') or { 'exit ${code}; the server log says why' }
			os.rm('${socket}.err') or {}
			return error(why)
		}
		if os.exists(socket) {
			a := ask(socket, 'ping', '')
			// the process answering is the worker started, and no other at that path
			if a.code == 0 && a.err.trim_space() == '${p.pid}' {
				return Worker{
					p:       p
					socket:  socket
					stamp:   stamp
					read_at: read_at
					files:   a.out.int()
				}
			}
		}
		time.sleep(50 * time.millisecond)
	}
	return error('unreachable')
}

// stop stops a worker.
fn (mut w Worker) stop() {
	if w.p == unsafe { nil } {
		return
	}
	ask(w.socket, 'stop', '')
	for _ in 0 .. 100 {
		if !w.p.is_alive() {
			break
		}
		time.sleep(20 * time.millisecond)
	}
	if w.p.is_alive() {
		w.p.signal_kill()
	}
	w.p.wait()
	w.p.close()
	os.rm(w.socket) or {}
	w = Worker{}
}

// worker_socket is the socket of the n-th worker: beside the server's, or in the temporary
// directory where that path would be too long for a socket.
fn worker_socket(dir string, n int) string {
	return os.join_path(dir, 'w${n}.sock')
}

// private_dir makes a directory for the workers' sockets that only this user can enter: not the
// server's own directory, which others may write in (/tmp), where one could take a worker's path.
fn private_dir() !string {
	name := 'arxmodel-${os.getpid()}-${time.now().unix_milli()}'
	mut dir := os.join_path(os.temp_dir(), name)
	// a socket path is at most about 100 bytes (104 on some systems): a long TMPDIR is not used
	if worker_socket(dir, 99999).len >= 100 {
		dir = os.join_path('/tmp', name)
	}
	os.mkdir(dir, mode: 0o700)!
	$if !windows {
		st := os.stat(dir)!
		if st.mode & 0o077 != 0 || st.uid != u32(os.getuid()) {
			os.rmdir(dir) or {}
			return error('${dir}: not private to this user')
		}
	}
	return dir
}

// serve_worker reads the files once and answers at --socket until stopped, or until the server
// that started it is gone.
fn serve_worker(o Opts) {
	// the server, recorded before reading: gone while this reads, the worker is someone else's child
	parent := os.getppid()
	m, _, c, _ := merged(o, Out{
		err: true
	}, read_options(o))
	if m.failed.len > 0 {
		// no answer from a part of the files: the server says why, from this file
		os.write_file('${o.socket}.err', m.failed.map(it.msg).join('; ')) or {}
		exit(1)
	}
	mut l := listen_private(o.socket) or {
		eprintln('serve: ${o.socket}: ${err.msg()}')
		exit(2)
	}
	l.set_accept_timeout(5 * time.second)
	mut orphan := false
	for {
		// the listener blocks, so accept alone waits for ever: wait the timeout first, to see
		// the server go
		l.wait_for_accept() or {
			if os.getppid() != parent {
				orphan = true
				break // the server is gone
			}
			continue
		}
		mut conn := l.accept() or {
			if os.getppid() != parent {
				orphan = true
				break // the server is gone
			}
			continue
		}
		req := read_request(mut conn)
		if req == '' {
			conn.close() or {}
			continue
		}
		cmd, arg := req.all_before('\t'), req.all_after('\t')
		if cmd == 'stop' {
			send(mut conn, Answer{})
			conn.close() or {}
			break
		}
		a := match cmd {
			'values' { answer_values(&c, arg) }
			'get' { answer_get(&c, arg) }
			'list' { answer_list(&c, arg) }
			'ping' {
				Answer{
					out: '${c.view.set.docs.len}'
					err: '${os.getpid()}'
				}
			}
			else {
				Answer{
					err:  'unknown request ${cmd}\n'
					code: 2
				}
			}
		}
		send(mut conn, a)
		conn.close() or {}
	}
	l.close() or {}
	if orphan {
		// the server died without removing its workers' directory: this worker does
		dir := os.dir(o.socket)
		if os.file_name(dir).starts_with('arxmodel-') {
			os.rmdir_all(dir) or {}
		}
	}
}

// cmd_serve answers values, get and list over a Unix domain socket until stopped, or idle for
// --idle minutes; a worker holds the model (serve_worker).
fn cmd_serve(o Opts) {
	if o.socket == '' {
		eprintln('serve needs --socket PATH')
		exit(2)
	}
	if o.worker {
		serve_worker(o)
		return
	}
	if o.stop {
		ask(o.socket, 'stop', '').emit()
	}
	if o.reload {
		ask(o.socket, 'reload', '').emit()
	}
	if o.paths.len == 0 {
		eprintln('serve needs the files to serve')
		exit(2)
	}
	if os.exists(o.socket) {
		if mut conn := unix.connect_stream(o.socket) {
			conn.close() or {}
			eprintln('serve: a server answers at ${o.socket} already')
			exit(2)
		}
		if !is_socket(o.socket) {
			eprintln('serve: ${o.socket} is there and is no socket: not removed (another --socket?)')
			exit(2)
		}
		os.rm(o.socket) or {} // a server that stopped without removing it
	}
	dir := private_dir() or {
		eprintln('serve: ${err.msg()}')
		exit(2)
	}
	// removed on every way out: exit does not run a function's defers
	defer {
		os.rmdir_all(dir) or {}
	}
	mut started := 1
	mut w := start_worker(o, worker_socket(dir, started)) or {
		os.rmdir_all(dir) or {}
		eprintln('serve: ${err.msg()}')
		exit(2)
	}
	mut l := listen_private(o.socket) or {
		w.stop()
		os.rmdir_all(dir) or {}
		eprintln('serve: ${o.socket}: ${err.msg()}')
		exit(2)
	}
	idle := if o.idle < 0 { 60 } else { o.idle }
	if idle > 0 {
		l.set_accept_timeout(idle * time.minute)
	}
	eprintln('serving ${plural(w.files, 'file')} at ${o.socket}${if idle > 0 {
		', stopping after ${idle} idle minutes'
	} else {
		''
	}}')
	for {
		if idle > 0 {
			// the listener blocks, so accept alone waits for ever: wait the idle time first
			l.wait_for_accept() or {
				eprintln('serve: idle for ${idle} minutes, stopping')
				break
			}
		}
		mut conn := l.accept() or {
			eprintln('serve: ${if idle > 0 { 'idle for ${idle} minutes' } else { err.msg() }}, stopping')
			break
		}
		req := read_request(mut conn)
		if req == '' {
			conn.close() or {} // nothing asked in time
			continue
		}
		cmd, arg := req.all_before('\t'), req.all_after('\t')
		if cmd == 'stop' {
			send(mut conn, Answer{
				err: 'stopped the server at ${o.socket}\n'
			})
			conn.close() or {}
			break
		}
		mut note := ''
		mut a := Answer{}
		mut tries := 0
		for {
			if cmd in ['values', 'get', 'list', 'reload'] {
				now := stamps(o)
				n := changed(w.stamp, now, w.read_at)
				if (cmd == 'reload' && tries == 0) || n > 0 || w.p == unsafe { nil }
					|| !w.p.is_alive() {
					w.stop()
					started++
					w = start_worker(o, worker_socket(dir, started)) or {
						a = Answer{
							err:  'the files cannot be read now (${err.msg()}): ask again\n'
							code: 2
						}
						break
					}
					note = 'read again: ${if n > 0 {
						plural(n, 'file') + ' changed'
					} else {
						'asked to'
					}}\n'
				}
			}
			a = match cmd {
				'values', 'get', 'list' { ask(w.socket, cmd, arg) }
				'reload', 'ping' {
					Answer{
						err: 'serving ${plural(w.files, 'file')}\n'
					}
				}
				else {
					Answer{
						err:  'unknown request ${cmd}\n'
						code: 2
					}
				}
			}
			if cmd !in ['values', 'get', 'list'] {
				break
			}
			// a file written while the worker answered: that answer is from changed files (a file
			// dated the second the model was read in, written after it: start_worker waits)
			after := stamps(o)
			if changed(w.stamp, after, w.read_at) == 0 {
				break
			}
			tries++
			if tries == 3 {
				a = Answer{
					err:  'the files kept changing while the answer was made: ask again\n'
					code: 2
				}
				break
			}
		}
		send(mut conn, Answer{
			out:  a.out
			err:  note + a.err
			code: a.code
		})
		conn.close() or {}
	}
	w.stop()
	l.close() or {}
}
