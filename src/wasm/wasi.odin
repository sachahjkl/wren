package wasm

// The subset of WASI preview 1 (module wasi_snapshot_preview1) that a C program built against wasi-libc needs to run
// inside the browser's sandbox: clocks, random bytes, standard output and error, empty arguments and environment.
// Nothing reaches the file system or the network: there are no preopened directories, every descriptor other than
// 0, 1 and 2 is EBADF, and every path or socket call is ENOTCAPABLE. Standard output and error go to `wasi_output`
// (the console of the page owning the instance, when the embedder sets it).
//
// The JavaScript engine (native/js) is such a program; any other guest may import these functions as well. They are
// defined on the shared Linker like every host function (registered by `register_wasi`), for every realm.

import "core:fmt"
import "core:os"
import "core:time"
import "wb:base"

WASI_MODULE :: "wasi_snapshot_preview1"

// Where a guest's standard output (fd 1) and error (fd 2) go. Called on the instance's own thread.
Wasi_Output_Proc :: #type proc(inst: ^Instance, fd: i32, text: []u8)

wasi_output: Wasi_Output_Proc = wasi_output_stderr

wasi_output_stderr :: proc(inst: ^Instance, fd: i32, text: []u8) {
	os.write(os.stderr, text)
}

@(private) WASI_ESUCCESS :: 0
@(private) WASI_EBADF :: 8
@(private) WASI_EFAULT :: 21
@(private) WASI_EINVAL :: 28
@(private) WASI_EIO :: 29
@(private) WASI_ENOSYS :: 52
@(private) WASI_ESPIPE :: 70
@(private) WASI_ENOTCAPABLE :: 76

@(private) WASI_FILETYPE_CHARACTER_DEVICE :: 2
@(private) WASI_RIGHT_FD_WRITE :: u64(1) << 6
@(private) WASI_RIGHT_FD_READ :: u64(1) << 1

@(private)
wasi_ret :: #force_inline proc "contextless" (a: [^]Raw, errno: i32) -> Trap {
	a[0] = {}
	a[0].i32 = errno
	return nil
}

// A checked view of `n` bytes at guest address `off` (wasm32 addresses: preview 1 has no 64-bit form).
@(private)
wasi_mem :: #force_inline proc "contextless" (f: ^Frame, off: i32, n: u64) -> ([^]u8, bool) {
	return span(f, u64(u32(off)), n)
}

@(private)
wasi_put_u32 :: #force_inline proc "contextless" (p: [^]u8, v: u32) { (^u32le)(p)^ = u32le(v) }
@(private)
wasi_put_u64 :: #force_inline proc "contextless" (p: [^]u8, v: u64) { (^u64le)(p)^ = u64le(v) }

// args_sizes_get / environ_sizes_get (count_ptr, buf_size_ptr): there are none.
@(private)
wasi_sizes_none :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	f := frame(env, caller)
	c, ok1 := wasi_mem(&f, a[0].i32, 4)
	s, ok2 := wasi_mem(&f, a[1].i32, 4)
	if !ok1 || !ok2 { return wasi_ret(a, WASI_EFAULT) }
	wasi_put_u32(c, 0)
	wasi_put_u32(s, 0)
	return wasi_ret(a, WASI_ESUCCESS)
}

// args_get / environ_get (ptrs, buf): nothing to write.
@(private)
wasi_list_none :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap { return wasi_ret(a, WASI_ESUCCESS) }

// clock_res_get(id, resolution_ptr)
@(private)
wasi_clock_res_get :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	f := frame(env, caller)
	if a[0].i32 < 0 || a[0].i32 > 3 { return wasi_ret(a, WASI_EINVAL) }
	p, ok := wasi_mem(&f, a[1].i32, 8)
	if !ok { return wasi_ret(a, WASI_EFAULT) }
	wasi_put_u64(p, a[0].i32 == 0 ? 100 : 1)   // the system time is in 100 ns units, the performance counter finer
	return wasi_ret(a, WASI_ESUCCESS)
}

// clock_time_get(id, precision: i64, time_ptr): realtime (0) from the system clock, the others from the monotonic one.
@(private)
wasi_clock_time_get :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	f := frame(env, caller)
	id := a[0].i32
	if id < 0 || id > 3 { return wasi_ret(a, WASI_EINVAL) }
	p, ok := wasi_mem(&f, a[2].i32, 8)
	if !ok { return wasi_ret(a, WASI_EFAULT) }
	ns: i64
	if id == 0 {
		ns = time.time_to_unix_nano(time.now())
	} else {
		ns = i64(time.tick_now()._nsec)
	}
	wasi_put_u64(p, u64(ns))
	return wasi_ret(a, WASI_ESUCCESS)
}

// random_get(buf, len)
@(private)
wasi_random_get :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	context = base.process_context()
	f := frame(env, caller)
	n := u64(u32(a[1].i32))
	p, ok := wasi_mem(&f, a[0].i32, n)
	if !ok { return wasi_ret(a, WASI_EFAULT) }
	if n > 0 && !random_fill(p[:n]) { return wasi_ret(a, WASI_EIO) }
	return wasi_ret(a, WASI_ESUCCESS)
}

// fd_write(fd, iovs, iovs_len, nwritten_ptr): fd 1 and 2 only.
@(private)
wasi_fd_write :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	context = base.process_context()
	f := frame(env, caller)
	fd := a[0].i32
	if fd != 1 && fd != 2 { return wasi_ret(a, WASI_EBADF) }
	count := u64(u32(a[2].i32))
	iovs, ok := wasi_mem(&f, a[1].i32, count * 8)
	if !ok { return wasi_ret(a, WASI_EFAULT) }
	out, ok2 := wasi_mem(&f, a[3].i32, 4)
	if !ok2 { return wasi_ret(a, WASI_EFAULT) }
	total: u64
	for i in 0 ..< count {
		base := u64((^u32le)(&iovs[i * 8])^)
		n := u64((^u32le)(&iovs[i * 8 + 4])^)
		p, okb := span(&f, base, n)
		if !okb { return wasi_ret(a, WASI_EFAULT) }
		if n > 0 && wasi_output != nil { wasi_output(f.inst, fd, p[:n]) }
		total += n
	}
	wasi_put_u32(out, u32(total))
	return wasi_ret(a, WASI_ESUCCESS)
}

// fd_read(fd, iovs, iovs_len, nread_ptr): standard input is empty, there is nothing else.
@(private)
wasi_fd_read :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	f := frame(env, caller)
	if a[0].i32 != 0 { return wasi_ret(a, WASI_EBADF) }
	out, ok := wasi_mem(&f, a[3].i32, 4)
	if !ok { return wasi_ret(a, WASI_EFAULT) }
	wasi_put_u32(out, 0)
	return wasi_ret(a, WASI_ESUCCESS)
}

// fd_fdstat_get(fd, stat_ptr): 0, 1 and 2 are character devices.
@(private)
wasi_fd_fdstat_get :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	f := frame(env, caller)
	fd := a[0].i32
	if fd < 0 || fd > 2 { return wasi_ret(a, WASI_EBADF) }
	p, ok := wasi_mem(&f, a[1].i32, 24)
	if !ok { return wasi_ret(a, WASI_EFAULT) }
	for i in 0 ..< 24 { p[i] = 0 }
	p[0] = WASI_FILETYPE_CHARACTER_DEVICE
	wasi_put_u64(p[8:], fd == 0 ? WASI_RIGHT_FD_READ : WASI_RIGHT_FD_WRITE)
	return wasi_ret(a, WASI_ESUCCESS)
}

// fd_seek(fd, offset: i64, whence, newoffset_ptr), fd_tell...: the standard streams cannot seek.
@(private)
wasi_fd_seek :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	fd := a[0].i32
	return wasi_ret(a, fd >= 0 && fd <= 2 ? WASI_ESPIPE : WASI_EBADF)
}

// fd_close(fd), fd_sync, fd_datasync, fd_fdstat_set_flags(fd, flags)...: nothing is open but the standard streams.
@(private)
wasi_fd_std_only :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	fd := a[0].i32
	return wasi_ret(a, fd >= 0 && fd <= 2 ? WASI_ESUCCESS : WASI_EBADF)
}

// fd_prestat_get / fd_prestat_dir_name...: no preopened directory, so no file system at all.
@(private)
wasi_ebadf :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap { return wasi_ret(a, WASI_EBADF) }

// path_* and sock_*: refused.
@(private)
wasi_not_capable :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap { return wasi_ret(a, WASI_ENOTCAPABLE) }

@(private)
wasi_nosys :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap { return wasi_ret(a, WASI_ENOSYS) }

@(private)
wasi_success :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap { return wasi_ret(a, WASI_ESUCCESS) }

// proc_exit(code): the program asked to end. A trap is the only way out of the call; the instance stays as it is.
@(private)
wasi_proc_exit :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	context = base.process_context()
	msg := fmt.tprintf("the module called exit(%d)", a[0].i32)
	return trap_new(msg)
}

@(private) I :: Val_Kind.I32
@(private) L :: Val_Kind.I64

@(private)
WASI_IMPORTS := [?]Import{
	{module = WASI_MODULE, name = "args_sizes_get", fn = wasi_sizes_none, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "args_get", fn = wasi_list_none, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "environ_sizes_get", fn = wasi_sizes_none, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "environ_get", fn = wasi_list_none, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "clock_res_get", fn = wasi_clock_res_get, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "clock_time_get", fn = wasi_clock_time_get, params = {I, L, I}, results = {I}},
	{module = WASI_MODULE, name = "random_get", fn = wasi_random_get, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_write", fn = wasi_fd_write, params = {I, I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_read", fn = wasi_fd_read, params = {I, I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_pwrite", fn = wasi_fd_seek, params = {I, I, I, L, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_pread", fn = wasi_fd_seek, params = {I, I, I, L, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_fdstat_get", fn = wasi_fd_fdstat_get, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_fdstat_set_flags", fn = wasi_fd_std_only, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_seek", fn = wasi_fd_seek, params = {I, L, I, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_tell", fn = wasi_fd_seek, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_close", fn = wasi_fd_std_only, params = {I}, results = {I}},
	{module = WASI_MODULE, name = "fd_sync", fn = wasi_fd_std_only, params = {I}, results = {I}},
	{module = WASI_MODULE, name = "fd_datasync", fn = wasi_fd_std_only, params = {I}, results = {I}},
	{module = WASI_MODULE, name = "fd_filestat_get", fn = wasi_ebadf, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_prestat_get", fn = wasi_ebadf, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_prestat_dir_name", fn = wasi_ebadf, params = {I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_readdir", fn = wasi_ebadf, params = {I, I, I, L, I}, results = {I}},
	{module = WASI_MODULE, name = "fd_renumber", fn = wasi_ebadf, params = {I, I}, results = {I}},
	{module = WASI_MODULE, name = "path_open", fn = wasi_not_capable, params = {I, I, I, I, I, L, L, I, I}, results = {I}},
	{module = WASI_MODULE, name = "path_filestat_get", fn = wasi_not_capable, params = {I, I, I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "path_create_directory", fn = wasi_not_capable, params = {I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "path_remove_directory", fn = wasi_not_capable, params = {I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "path_unlink_file", fn = wasi_not_capable, params = {I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "path_rename", fn = wasi_not_capable, params = {I, I, I, I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "path_readlink", fn = wasi_not_capable, params = {I, I, I, I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "poll_oneoff", fn = wasi_nosys, params = {I, I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "sched_yield", fn = wasi_success, params = {}, results = {I}},
	{module = WASI_MODULE, name = "proc_exit", fn = wasi_proc_exit, params = {I}, results = {}},
	{module = WASI_MODULE, name = "sock_accept", fn = wasi_not_capable, params = {I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "sock_recv", fn = wasi_not_capable, params = {I, I, I, I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "sock_send", fn = wasi_not_capable, params = {I, I, I, I, I}, results = {I}},
	{module = WASI_MODULE, name = "sock_shutdown", fn = wasi_not_capable, params = {I, I}, results = {I}},
}

// Registers the WASI functions for every kind of instance. Safe to call more than once.
register_wasi :: proc() -> bool {
	for &im in WASI_IMPORTS { im.realms = max(u32) }
	return register(WASI_IMPORTS[:])
}
