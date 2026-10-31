package wasm

// Memory that several agents have: a shared WebAssembly.Memory and a SharedArrayBuffer of a page, the same thing here. The
// JavaScript engine's own memory cannot be shared between realms (docs/shared-memory.md), so the bytes are a Wasmtime shared
// memory, outside every realm: a module reaches them by its instructions, a script through a host buffer (Buffer_Host in
// src/engine/jsrt), its Atomics through the calls below.
//
// `memory.atomic.wait` of a module and of Atomics.wait must find each other, and the place where waiters park belongs to
// the memory inside Wasmtime, which only those instructions reach: each store has a small module importing the memory (WAIT_MODULE).
//
// Between agents a memory or a module goes by a token of the agent cluster (Shared_Cluster): the bytes of a message pass
// through the engine's memory, so a token is worth something only in its cluster, and unguessable.

import "core:crypto"
import "core:sync"
import "core:time"
import "wb:base"

// The numbers of shared memories start here, among the numbers of a store's memories.
USER_SHARED_BASE :: i32(1 << 20)

// One slice of a blocking wait (user_shared_wait; translate_shared_waits for a module's): how late a stopping realm notices.
WAIT_SLICE_NS :: i64(50_000_000)

Shared_Memory :: struct {
	handle:      rawptr,   // (each user has its clone of it)
	data:        [^]u8,    // (never moves: wasmtime_config_memory_may_move_set)
	byte_length: int,      // atomic: what a SharedArrayBuffer says, which needs not be a whole number of pages
	refs:        i32,      // atomic
}

@(private)
User_Shared :: struct {
	memory:       ^Shared_Memory,
	uses:         int,      // of the realm's script (user_shared_release); a Memory object is one for good
	wait_ready:   bool,
	wait32, wait64, notify: wt_func,
}

// What a cluster's agents have sent each other.
@(private = "file")
Shared_Token :: struct {
	cluster: u64,
	memory:  ^Shared_Memory,   // one of the two
	module:  ^User_Module,
}

@(private = "file")
shared_tokens: struct {
	mu:       sync.Mutex,
	tokens:   map[u64]Shared_Token,
	clusters: map[u64]int,   // how many realms are in it
	next:     u64,
}

// A new agent cluster, with one realm in it.
user_cluster_new :: proc() -> u64 {
	context.allocator = base.process_allocator()
	sync.mutex_guard(&shared_tokens.mu)
	shared_tokens.next += 1
	shared_tokens.clusters[shared_tokens.next] = 1
	return shared_tokens.next
}

user_cluster_retain :: proc(id: u64) {
	context.allocator = base.process_allocator()
	sync.mutex_guard(&shared_tokens.mu)
	if id in shared_tokens.clusters { shared_tokens.clusters[id] += 1 }
}

// A realm has gone. With the last one, what they sent goes: nobody can receive it any more.
user_cluster_release :: proc(id: u64) {
	context.allocator = base.process_allocator()
	gone := make([dynamic]Shared_Token, context.temp_allocator)
	{
		sync.mutex_guard(&shared_tokens.mu)
		n, ok := shared_tokens.clusters[id]
		if !ok { return }
		if n > 1 {
			shared_tokens.clusters[id] = n - 1
			return
		}
		delete_key(&shared_tokens.clusters, id)
		for token, t in shared_tokens.tokens {
			if t.cluster != id { continue }
			append(&gone, t)
			delete_key(&shared_tokens.tokens, token)
		}
		// (no cluster left: nothing of this stays allocated)
		if len(shared_tokens.clusters) == 0 {
			delete(shared_tokens.clusters)
			delete(shared_tokens.tokens)
			shared_tokens.clusters, shared_tokens.tokens = nil, nil
		}
	}
	for t in gone {
		if t.memory != nil { shared_memory_release(t.memory) }
		if t.module != nil { user_module_delete(t.module) }
	}
}

@(private = "file")
token_new :: proc(t: Shared_Token) -> u64 {
	context.allocator = base.process_allocator()
	sync.mutex_guard(&shared_tokens.mu)
	if t.cluster not_in shared_tokens.clusters { return 0 }
	token: u64
	for {
		crypto.rand_bytes(([^]u8)(&token)[:8])
		if token != 0 && token not_in shared_tokens.tokens { break }
	}
	shared_tokens.tokens[token] = t
	return token
}

@(private = "file")
token_get :: proc(token, cluster: u64) -> (t: Shared_Token, ok: bool) {
	sync.mutex_guard(&shared_tokens.mu)
	t, ok = shared_tokens.tokens[token]
	return t, ok && t.cluster == cluster
}

// A module for another agent of the cluster (it goes with the cluster, or with the receivers' objects).
user_module_share :: proc(m: ^User_Module, cluster: u64) -> u64 {
	sync.atomic_add(&m.refs, 1)
	token := token_new(Shared_Token{cluster = cluster, module = m})
	if token == 0 { user_module_delete(m) }
	return token
}

// What the token stands for, one more reference of it: nil when it is not of this cluster.
user_module_adopt :: proc(token, cluster: u64) -> ^User_Module {
	t, ok := token_get(token, cluster)
	if !ok || t.module == nil { return nil }
	sync.atomic_add(&t.module.refs, 1)
	return t.module
}

// ---- the memory ----

@(private = "file")
shared_memory_release :: proc(m: ^Shared_Memory) {
	if sync.atomic_sub(&m.refs, 1) != 1 { return }
	wasmtime_sharedmemory_delete(m.handle)
	free(m, base.process_allocator())
}

// Takes `handle`.
@(private = "file")
shared_memory_wrap :: proc(handle: rawptr, byte_length: int) -> ^Shared_Memory {
	m := new(Shared_Memory, base.process_allocator())
	m.handle, m.data, m.byte_length, m.refs = handle, wasmtime_sharedmemory_data(handle), byte_length, 1
	return m
}

// Takes one reference of `m`.
@(private = "file")
store_add_shared :: proc(s: ^User_Store, m: ^Shared_Memory) -> i32 {
	append(&s.shared, User_Shared{memory = m, uses = 1})
	return USER_SHARED_BASE + i32(len(s.shared) - 1)
}

@(private = "file")
shared_at :: proc(s: ^User_Store, id: i32) -> ^User_Shared {
	i := int(id) - int(USER_SHARED_BASE)
	if i < 0 || i >= len(s.shared) || s.shared[i].memory == nil { return nil }
	return &s.shared[i]
}

user_store_delete_shared :: proc(s: ^User_Store) {
	for &x in s.shared { if x.memory != nil { shared_memory_release(x.memory) } }
	delete(s.shared)
}

user_memory_is_shared :: proc(id: i32) -> bool { return id >= USER_SHARED_BASE }

// `byte_length` < 0: all of its pages.
user_shared_new :: proc(s: ^User_Store, initial, maximum: i64, byte_length: i64 = -1) -> (id: i32, f: User_Failure) {
	if initial < 0 || initial > 65536 || maximum < initial || maximum > 65536 { return 0, fail(s, .Range, "the size of the memory is out of range") }
	ty: wt_memorytype
	if e := wasmtime_memorytype_new(u64(initial), true, u64(maximum), false, true, 16, &ty); e != nil { return 0, fail_error(s, .Range, e) }
	defer wasm_memorytype_delete(ty)
	handle: rawptr
	if e := wasmtime_sharedmemory_new(wt.engine, ty, &handle); e != nil { return 0, fail_error(s, .Range, e) }
	return store_add_shared(s, shared_memory_wrap(handle, byte_length >= 0 ? int(byte_length) : int(initial) * 65536)), .None
}

// The number of a shared memory an instance exports (the memory JavaScript gave, or the module's own). Takes `handle`.
@(private)
user_shared_id :: proc(s: ^User_Store, handle: rawptr) -> i32 {
	data := wasmtime_sharedmemory_data(handle)
	for &x, i in s.shared {
		if x.memory != nil && x.memory.data == data {
			wasmtime_sharedmemory_delete(handle)
			return USER_SHARED_BASE + i32(i)
		}
	}
	return store_add_shared(s, shared_memory_wrap(handle, int(wasmtime_sharedmemory_data_size(handle))))
}

// What an instance importing this memory is given (the call does not take it).
@(private)
user_shared_handle :: proc(s: ^User_Store, id: i32) -> rawptr {
	x := shared_at(s, id)
	return x != nil ? x.memory.handle : nil
}

// A script no longer has this memory (a SharedArrayBuffer collected; a Memory object lives with the page).
user_shared_release :: proc(s: ^User_Store, id: i32) {
	x := shared_at(s, id)
	if x == nil { return }
	x.uses -= 1
	if x.uses > 0 { return }
	shared_memory_release(x.memory)
	x^ = {}
}

user_shared_pages :: proc(s: ^User_Store, id: i32) -> i64 {
	x := shared_at(s, id)
	return x != nil ? i64(wasmtime_sharedmemory_size(x.memory.handle)) : -1
}

user_shared_byte_length :: proc(s: ^User_Store, id: i32) -> i64 {
	x := shared_at(s, id)
	return x != nil ? i64(sync.atomic_load(&x.memory.byte_length)) : -1
}

user_shared_grow :: proc(s: ^User_Store, id: i32, delta: i64) -> (prev: i64, f: User_Failure) {
	x := shared_at(s, id)
	if x == nil || delta < 0 { return 0, fail(s, .Type, "not a memory") }
	p: u64
	if e := wasmtime_sharedmemory_grow(x.memory.handle, u64(delta), &p); e != nil {
		wasmtime_error_delete(e)
		return 0, fail(s, .Range, "Maximum memory size exceeded")
	}
	sync.atomic_store(&x.memory.byte_length, int(wasmtime_sharedmemory_data_size(x.memory.handle)))
	return i64(p), .None
}

// SharedArrayBuffer.grow: to `bytes`, its pages first.
user_shared_grow_bytes :: proc(s: ^User_Store, id: i32, bytes: i64) -> bool {
	x := shared_at(s, id)
	if x == nil { return false }
	pages := (bytes + 65535) / 65536
	have := i64(wasmtime_sharedmemory_size(x.memory.handle))
	if pages > have {
		p: u64
		if e := wasmtime_sharedmemory_grow(x.memory.handle, u64(pages - have), &p); e != nil {
			wasmtime_error_delete(e)
			return false
		}
	}
	for {
		old := sync.atomic_load(&x.memory.byte_length)
		if i64(old) >= bytes { return true }
		if _, ok := sync.atomic_compare_exchange_strong(&x.memory.byte_length, old, int(bytes)); ok { return true }
	}
}

user_shared_read :: proc(s: ^User_Store, id: i32, offset: i64, out: []u8) -> int {
	x := shared_at(s, id)
	if x == nil { return 0 }
	size := i64(wasmtime_sharedmemory_data_size(x.memory.handle))
	if offset < 0 || offset >= size { return 0 }
	n := min(i64(len(out)), size - offset)
	copy(out[:n], x.memory.data[offset:offset + n])
	return int(n)
}

user_shared_write :: proc(s: ^User_Store, id: i32, offset: i64, bytes: []u8) -> int {
	x := shared_at(s, id)
	if x == nil { return 0 }
	size := i64(wasmtime_sharedmemory_data_size(x.memory.handle))
	if offset < 0 || offset >= size { return 0 }
	n := min(i64(len(bytes)), size - offset)
	copy(x.memory.data[offset:offset + n], bytes[:n])
	return int(n)
}

// A shared memory for another agent of the cluster.
user_shared_share :: proc(s: ^User_Store, id: i32, cluster: u64) -> u64 {
	x := shared_at(s, id)
	if x == nil { return 0 }
	sync.atomic_add(&x.memory.refs, 1)
	token := token_new(Shared_Token{cluster = cluster, memory = x.memory})
	if token == 0 { shared_memory_release(x.memory) }
	return token
}

// The memory of a token, in this store: -1 when the token is not of this cluster. The same memory is the same number.
user_shared_adopt :: proc(s: ^User_Store, token, cluster: u64) -> i32 {
	t, ok := token_get(token, cluster)
	if !ok || t.memory == nil { return -1 }
	for &x, i in s.shared {
		if x.memory == t.memory {
			x.uses += 1
			return USER_SHARED_BASE + i32(i)
		}
	}
	sync.atomic_add(&t.memory.refs, 1)
	return store_add_shared(s, t.memory)
}

// ---- Atomics ----

Shared_Atomic_Op :: enum i32 { Add, And, Compare_Exchange, Exchange, Load, Or, Store, Sub, Xor }

// One read-modify-write on the element of `size` bytes at `offset`, aligned, of the buffer: the value it held. `a`
// (and `b`: the replacement of a compare-exchange) in the low bits.
user_shared_atomic :: proc(s: ^User_Store, id: i32, op: Shared_Atomic_Op, offset: i64, size: i32, a, b: u64) -> u64 {
	x := shared_at(s, id)
	if x == nil { return 0 }
	end := i64(wasmtime_sharedmemory_data_size(x.memory.handle))
	if offset < 0 || offset + i64(size) > end || offset & i64(size - 1) != 0 { return 0 }
	run :: proc(p: ^$T, op: Shared_Atomic_Op, a, b: u64) -> u64 {
		switch op {
		case .Add: return u64(sync.atomic_add(p, T(a)))
		case .And: return u64(sync.atomic_and(p, T(a)))
		case .Compare_Exchange:
			old, _ := sync.atomic_compare_exchange_strong(p, T(a), T(b))
			return u64(old)
		case .Exchange: return u64(sync.atomic_exchange(p, T(a)))
		case .Load: return u64(sync.atomic_load(p))
		case .Or: return u64(sync.atomic_or(p, T(a)))
		case .Store:
			sync.atomic_store(p, T(a))
			return a
		case .Sub: return u64(sync.atomic_sub(p, T(a)))
		case .Xor: return u64(sync.atomic_xor(p, T(a)))
		}
		return 0
	}
	at := rawptr(&x.memory.data[offset])
	switch size {
	case 1: return run((^u8)(at), op, a, b)
	case 2: return run((^u16)(at), op, a, b)
	case 4: return run((^u32)(at), op, a, b)
	case 8: return run((^u64)(at), op, a, b)
	}
	return 0
}

// (module (import "m" "m" (memory 0 65536 shared))
//   (func (export "w32") (param i32 i32 i64) (result i32) local.get 0 local.get 1 local.get 2 memory.atomic.wait32)
//   (func (export "w64") (param i32 i64 i64) (result i32) local.get 0 local.get 1 local.get 2 memory.atomic.wait64)
//   (func (export "n") (param i32 i32) (result i32) local.get 0 local.get 1 memory.atomic.notify))
@(private = "file")
WAIT_MODULE := [?]u8{
	0, 'a', 's', 'm', 1, 0, 0, 0,
	1, 21, 3, 0x60, 3, 0x7f, 0x7f, 0x7e, 1, 0x7f, 0x60, 3, 0x7f, 0x7e, 0x7e, 1, 0x7f, 0x60, 2, 0x7f, 0x7f, 1, 0x7f,
	2, 11, 1, 1, 'm', 1, 'm', 2, 3, 0, 0x80, 0x80, 4,
	3, 4, 3, 0, 1, 2,
	7, 17, 3, 3, 'w', '3', '2', 0, 0, 3, 'w', '6', '4', 0, 1, 1, 'n', 0, 2,
	10, 38, 3,
	12, 0, 0x20, 0, 0x20, 1, 0x20, 2, 0xfe, 1, 2, 0, 0x0b,
	12, 0, 0x20, 0, 0x20, 1, 0x20, 2, 0xfe, 2, 3, 0, 0x0b,
	10, 0, 0x20, 0, 0x20, 1, 0xfe, 0, 2, 0, 0x0b,
}

@(private = "file")
wait_module: struct {
	once:   sync.Once,
	module: wt_module,
}

// The functions that reach this memory's waiters, in this store.
@(private = "file")
wait_functions :: proc(s: ^User_Store, x: ^User_Shared) -> bool {
	if x.wait_ready { return true }
	sync.once_do(&wait_module.once, proc() {
		if e := wasmtime_module_new(wt.engine, &WAIT_MODULE[0], len(WAIT_MODULE), &wait_module.module); e != nil { wasmtime_error_delete(e) }
	})
	if wait_module.module == nil { return false }
	item := wt_extern{kind = WT_EXTERN_SHAREDMEMORY}
	item.of.sharedmemory = x.memory.handle
	inst: wt_instance
	trap: wt_trap
	if e := wasmtime_instance_new(s.ctx, wait_module.module, &item, 1, &inst, &trap); e != nil {
		wasmtime_error_delete(e)
		return false
	}
	if trap != nil {
		wasm_trap_delete(trap)
		return false
	}
	get :: proc(s: ^User_Store, inst: ^wt_instance, name: string, out: ^wt_func) -> bool {
		ext: wt_extern
		if !wasmtime_instance_export_get(s.ctx, inst, raw_data(name), uint(len(name)), &ext) { return false }
		out^ = ext.of.func
		return true
	}
	if !get(s, &inst, "w32", &x.wait32) || !get(s, &inst, "w64", &x.wait64) || !get(s, &inst, "n", &x.notify) { return false }
	x.wait_ready = true
	return true
}

@(private = "file")
call_cell :: proc(s: ^User_Store, fn: ^wt_func, args: []wt_val) -> (result: i32, ok: bool) {
	r: wt_val
	trap: wt_trap
	wasmtime_context_set_epoch_deadline(s.ctx, 1)
	if e := wasmtime_func_call(s.ctx, fn, raw_data(args), uint(len(args)), &r, 1, &trap); e != nil {
		wasmtime_error_delete(e)
		return 0, false
	}
	if trap != nil {
		wasm_trap_delete(trap)
		return 0, false
	}
	return r.of.i32, true
}

// Atomics.wait on the 4 or 8 bytes at `offset`: 0 woken, 1 not equal, 2 timed out. `stop`: the realm is being stopped, which
// reads as timed out (nothing of the realm runs after). timeout_ms < 0: none.
user_shared_wait :: proc(s: ^User_Store, id: i32, offset: i64, size: i32, expected: u64, timeout_ms: f64) -> i32 {
	x := shared_at(s, id)
	if x == nil || !wait_functions(s, x) { return 2 }
	limit := time.tick_now()
	remaining := i64(-1)
	if timeout_ms >= 0 { remaining = timeout_ms >= 9e12 ? max(i64) : i64(timeout_ms * 1e6) }
	first := true
	for {
		slice := remaining < 0 || remaining > WAIT_SLICE_NS ? WAIT_SLICE_NS : remaining
		args := [3]wt_val{{kind = WASM_I32}, {kind = size == 8 ? WASM_I64 : WASM_I32}, {kind = WASM_I64}}
		args[0].of.i32 = i32(u32(offset))
		if size == 8 { args[1].of.i64 = i64(expected) } else { args[1].of.i32 = i32(u32(expected)) }
		args[2].of.i64 = slice
		r, ok := call_cell(s, size == 8 ? &x.wait64 : &x.wait32, args[:])
		if !ok { return 2 }
		switch r {
		case 0: return 0
		case 1: return first ? 1 : 0   // (it changed while between two slices: what a notify would have told)
		}
		first = false
		if stop := s.inst.opt.stop; stop != nil && sync.atomic_load(stop) { return 2 }
		if remaining >= 0 {
			remaining = i64(timeout_ms * 1e6) - i64(time.tick_since(limit))
			if remaining <= 0 { return 2 }
		}
	}
}

// Atomics.notify: how many waiters it woke.
user_shared_notify :: proc(s: ^User_Store, id: i32, offset: i64, count: u32) -> i32 {
	x := shared_at(s, id)
	if x == nil || !wait_functions(s, x) { return 0 }
	args := [2]wt_val{{kind = WASM_I32}, {kind = WASM_I32}}
	args[0].of.i32 = i32(u32(offset))
	args[1].of.i32 = i32(count)
	r, _ := call_cell(s, &x.notify, args[:])
	return r
}
