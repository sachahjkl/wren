// web_wasm.odin: the WebAssembly JavaScript API (api/webassembly.odin, src/page/webassembly.odin on the browser's side):
// a page's own modules, compiled and run by Wasmtime beside the engine's instance. Hand-written (the generated bindings
// have no namespace of constructors): the natives here, the objects over them in web_wasm.js; they exist only when the
// browser says so (javascript.webassembly.enabled).
//
// A value crosses as a cell (an i64) of the type a letter says (src/wasm/user_store.odin): the conversions of the
// specification are here, so a call costs no JavaScript beyond the function called.
package odin_glue

import "../odin/wj"

// What web_wasm.js gives once (native.setup): the errors to throw and what maps functions and externrefs to numbers.
@(private = "file")
Wasm_Realm :: struct {
	link_error, runtime_error: wj.JSValue,
	func_id, func_wrap:        wj.JSValue,   // (function) -> its number, or undefined; (number) -> its function
	extern_id, extern_value:   wj.JSValue,   // (any) -> its number; (number) -> the value
	to_list:                   wj.JSValue,   // (iterable) -> an array: what a function with several results returns
	exception_make:            wj.JSValue,   // (tag number, values) -> a WebAssembly.Exception
	exception_info:            wj.JSValue,   // (any) -> [tag number, values], undefined when it is no WebAssembly.Exception
	pending:                  wj.JSValue,   // what an import threw, for the call into the module that got there
	has_pending:               bool,
	imports:                   [^]Wasm_Import,
	imports_n, imports_cap:    i32,
	sigs:                      [^]cstring,   // by a function's number, as they are wrapped
	sigs_cap:                  i32,
}

@(private = "file")
Wasm_Import :: struct {
	fn:  wj.JSValue,
	sig: cstring,
}

@(private = "file") wr: Wasm_Realm

@(private = "file") SMALL_CELLS :: 8      // values of a call kept on the engine's stack (a deep recursion through a module runs out of it first); more take the heap
@(private = "file") MAX_TAG_VALUES :: 32  // values of an exception

// WebAssembly.validate(bytes)
@(private = "file")
wasm_validate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_type(ctx, "WebAssembly.validate(): Argument 0 must be a buffer source") }
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, argv[0], &p, &n, wj.BS_ALLOW_SHARED, "WebAssembly.validate()") { return wj.EXCEPTION }
	if n > 0xFFFF_FFFF { return wj.FALSE }
	ok := wj.wr_WebAssembly_validate(n > 0 ? p : wj.empty_ptr(), u32(n))
	return ok != 0 ? wj.TRUE : wj.FALSE
}

// A compiled module in the browser, for web_wasm.js: an object with nothing to see, which releases it when collected.
@(private = "file") wasm_handle_class: wj.Class_ID

@(private = "file")
wasm_handle_finalizer :: proc "c" (rt: ^wj.Runtime, val: wj.JSValue) {
	h := (^u64)(wj.JS_GetOpaque(val, wasm_handle_class))
	if h == nil { return }
	wj.wr_Object_release(h^)
	wj.libc_free(h)
}

@(private = "file")
wasm_handle_of :: proc "contextless" (v: wj.JSValue) -> u64 {
	h := (^u64)(wj.JS_GetOpaque(v, wasm_handle_class))
	return h != nil ? h^ : 0
}

// `module` as a handle object (takes it).
@(private = "file")
wasm_handle_new :: proc "contextless" (ctx: ^wj.Context, module: u64) -> wj.JSValue {
	h := (^u64)(wj.libc_malloc(size_of(u64)))
	if h == nil { wj.wr_Object_release(module); return wj.JS_ThrowOutOfMemory(ctx) }
	h^ = module
	obj := wj.JS_NewObjectClass(ctx, wasm_handle_class)
	if wj.is_exception(obj) { wj.wr_Object_release(module); wj.libc_free(h); return obj }
	wj.JS_SetOpaque(obj, h)
	return obj
}

// compile(bytes): the handle of the module, or a string, the reason it did not compile.
@(private = "file")
wasm_compile :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, wj.arg(argc, argv, 0), &p, &n, wj.BS_ALLOW_SHARED, "WebAssembly.Module()") { return wj.EXCEPTION }
	if n > 0xFFFF_FFFF { return wj.JS_ThrowRangeError(ctx, "WebAssembly.Module(): the module is too large") }
	module: u64
	if st := wj.wr_WebAssembly_compile(n > 0 ? p : wj.empty_ptr(), u32(n), &module); st < 0 {
		m := wj.fetch_string(wj.wr_Exception_message)
		return wj.JS_NewStringLen(ctx, wj.wj_scratch.data, m > 0 ? uint(m) : 0)
	}
	return wasm_handle_new(ctx, module)
}

// What compileAsync's promise settles with: `finish` (the promise's data) called with the handle, or with the reason as
// a string; it makes the Module or throws the CompileError.
@(private = "file")
wasm_compile_settle :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	arg := reject^ ? wj.wj_host_promise_text(ctx, host) : wasm_handle_new(ctx, u64(value))
	if wj.is_exception(arg) { return arg }
	defer wj.JS_FreeValue(ctx, arg)
	reject^ = false
	return wj.JS_Call(ctx, data, wj.UNDEFINED, 1, &arg)
}

// compileAsync(bytes, finish): the promise of what `finish` makes of the compilation (wasm_compile_settle).
@(private = "file")
wasm_compile_async :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, wj.arg(argc, argv, 0), &p, &n, wj.BS_ALLOW_SHARED, "WebAssembly.compile()") { return wj.EXCEPTION }
	if n > 0xFFFF_FFFF { return wj.JS_ThrowRangeError(ctx, "WebAssembly.compile(): the module is too large") }
	return wj.wj_promise_from_host(ctx, wj.wr_WebAssembly_compileAsync(n > 0 ? p : wj.empty_ptr(), u32(n)), 0, wasm_compile_settle, wj.arg(argc, argv, 1))
}

// The JSON the browser wrote of a module, as the values it describes.
@(private = "file")
wasm_described :: proc "contextless" (ctx: ^wj.Context, a: u64, b: i32, fill: proc "contextless" (u64, i32, [^]u8, u32) -> i32) -> wj.JSValue {
	// (JS_ParseJSON reads a NUL-terminated buffer: one byte is kept for it)
	if wj.wj_scratch.cap < 2 && !wj.wj_scratch_grow(4096) { return wj.JS_ThrowOutOfMemory(ctx) }
	n := fill(a, b, wj.wj_scratch.data, wj.wj_scratch.cap - 1)
	if n >= 0 && u32(n) >= wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(n) + 1) { return wj.JS_ThrowOutOfMemory(ctx) }
		n = fill(a, b, wj.wj_scratch.data, wj.wj_scratch.cap - 1)
	}
	if n < 0 { return wj.wj_throw_status(ctx, n, "WebAssembly.Module") }
	wj.wj_scratch.data[n] = 0
	return wj.JS_ParseJSON(ctx, wj.wj_scratch.data, uint(n), "<WebAssembly.Module>")
}

@(private = "file")
wasm_imports :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wasm_described(ctx, wasm_handle_of(wj.arg(argc, argv, 0)), 0, proc "contextless" (m: u64, _: i32, buf: [^]u8, cap: u32) -> i32 { return wj.wr_WebAssembly_Module_imports(m, buf, cap) })
}

@(private = "file")
wasm_exports :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wasm_described(ctx, wasm_handle_of(wj.arg(argc, argv, 0)), 0, proc "contextless" (m: u64, _: i32, buf: [^]u8, cap: u32) -> i32 { return wj.wr_WebAssembly_Module_exports(m, buf, cap) })
}

@(private = "file")
wasm_link_info :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wasm_described(ctx, wasm_handle_of(wj.arg(argc, argv, 0)), 0, proc "contextless" (m: u64, _: i32, buf: [^]u8, cap: u32) -> i32 { return wj.wr_WebAssembly_Module_linkInfo(m, buf, cap) })
}

// customSections(handle, name): an array of ArrayBuffers (copies), in the order of the module
@(private = "file")
wasm_custom_sections :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	module := wasm_handle_of(wj.arg(argc, argv, 0))
	name: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &name, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	np := name.ptr != nil ? name.ptr : wj.empty_ptr()
	arr := wj.JS_NewArray(ctx)
	if wj.is_exception(arr) { return arr }
	count := wj.wr_WebAssembly_Module_customSectionCount(module, np, u32(name.len))
	for i in 0 ..< count {
		n := wj.wr_WebAssembly_Module_customSection(module, np, u32(name.len), i, wj.wj_scratch.data, wj.wj_scratch.cap)
		if n > 0 && u32(n) > wj.wj_scratch.cap {
			if !wj.wj_scratch_grow(u32(n)) { wj.JS_FreeValue(ctx, arr); return wj.JS_ThrowOutOfMemory(ctx) }
			n = wj.wr_WebAssembly_Module_customSection(module, np, u32(name.len), i, wj.wj_scratch.data, wj.wj_scratch.cap)
		}
		if n < 0 { wj.JS_FreeValue(ctx, arr); return wj.wj_throw_status(ctx, n, "WebAssembly.Module.customSections") }
		ab := wj.JS_NewArrayBufferCopy(ctx, n > 0 ? wj.wj_scratch.data : wj.empty_ptr(), uint(n))
		if wj.is_exception(ab) || wj.JS_DefinePropertyValueUint32(ctx, arr, u32(i), ab, wj.PROP_C_W_E) < 0 {
			wj.JS_FreeValue(ctx, arr)
			return wj.EXCEPTION
		}
	}
	return arr
}

// ---- failures ----

// Throws what the browser's failure `-status` stands for (the message: WebAssembly_lastError), or what an import threw.
@(private = "file")
wasm_throw :: proc "contextless" (ctx: ^wj.Context, status: i64, what: cstring) -> wj.JSValue {
	if wr.has_pending {
		wr.has_pending = false
		return wj.JS_Throw(ctx, wr.pending)   // (takes it)
	}
	if status == -5 { return wasm_throw_exception(ctx) }
	n := wj.fetch_string(wj.wr_WebAssembly_lastError)
	msg := wj.JS_NewStringLen(ctx, wj.wj_scratch.data, n > 0 ? uint(n) : 0)
	if wj.is_exception(msg) { return msg }
	defer wj.JS_FreeValue(ctx, msg)
	switch status {
	case -1, -2:
		e := wj.JS_CallConstructor(ctx, status == -1 ? wr.link_error : wr.runtime_error, 1, &msg)
		if wj.is_exception(e) { return e }
		return wj.JS_Throw(ctx, e)
	case -3: return wj.JS_ThrowRangeError(ctx, "%s: %.*s", what, max(n, 0), wj.wj_scratch.data)
	}
	return wj.JS_ThrowTypeError(ctx, "%s: %.*s", what, max(n, 0), wj.wj_scratch.data)
}

// The module threw and nothing caught it: a WebAssembly.Exception.
@(private = "file")
wasm_throw_exception :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	tag := wj.wr_WebAssembly_exception_tag()
	sig: [MAX_TAG_VALUES + 1]u8
	np := wj.wr_WebAssembly_Tag_sig(tag, &sig[0], MAX_TAG_VALUES)
	if np < 0 || np > MAX_TAG_VALUES { return wj.JS_ThrowRangeError(ctx, "the exception has too many values") }
	cells: [MAX_TAG_VALUES]i64
	if np > 0 { wj.wr_WebAssembly_Func_results(([^]u8)(&cells[0]), u32(np) * 8) }
	values := wj.JS_NewArray(ctx)
	if wj.is_exception(values) { return values }
	defer wj.JS_FreeValue(ctx, values)
	for i in 0 ..< np {
		v := wasm_from_cell(ctx, sig[i], cells[i])
		if wj.is_exception(v) || wj.JS_DefinePropertyValueUint32(ctx, values, u32(i), v, wj.PROP_C_W_E) < 0 { return wj.EXCEPTION }
	}
	args := [2]wj.JSValue{wj.new_int32(tag), values}
	e := wj.JS_Call(ctx, wr.exception_make, wj.UNDEFINED, 2, &args[0])
	if wj.is_exception(e) { return e }
	return wj.JS_Throw(ctx, e)
}

// What an import threw: true when it was a WebAssembly.Exception, now the browser's to throw in the module.
@(private = "file")
wasm_import_threw :: proc "contextless" (ctx: ^wj.Context, e: wj.JSValue) -> bool {
	a := e
	info := wj.JS_Call(ctx, wr.exception_info, wj.UNDEFINED, 1, &a)
	if wj.is_exception(info) { wj.drop_exception(ctx); return false }
	defer wj.JS_FreeValue(ctx, info)
	if wj.is_undefined(info) { return false }
	tv := wj.JS_GetPropertyUint32(ctx, info, 0)
	tag: i32
	wj.JS_ToInt32(ctx, &tag, tv)
	wj.JS_FreeValue(ctx, tv)
	values := wj.JS_GetPropertyUint32(ctx, info, 1)
	defer wj.JS_FreeValue(ctx, values)
	sig: [MAX_TAG_VALUES + 1]u8
	np := wj.wr_WebAssembly_Tag_sig(tag, &sig[0], MAX_TAG_VALUES)
	if np < 0 || np > MAX_TAG_VALUES { return false }
	cells: [MAX_TAG_VALUES]i64
	for i in 0 ..< np {
		v := wj.JS_GetPropertyUint32(ctx, values, u32(i))
		ok := wasm_to_cell(ctx, sig[i], v, &cells[i])
		wj.JS_FreeValue(ctx, v)
		if !ok { wj.drop_exception(ctx); return false }
	}
	wj.wr_WebAssembly_import_throw(tag, ([^]u8)(&cells[0]), u32(np) * 8)
	return true
}

// ---- values ----

@(private = "file")
wasm_to_cell :: proc "contextless" (ctx: ^wj.Context, letter: u8, v: wj.JSValue, cell: ^i64) -> bool {
	switch letter {
	case 'i':
		x: i32
		if wj.JS_ToInt32(ctx, &x, v) < 0 { return false }
		cell^ = i64(u32(x))
	case 'I':
		return wj.JS_ToBigInt64(ctx, cell, v) >= 0
	case 'f':
		d: f64
		if wj.JS_ToFloat64(ctx, &d, v) < 0 { return false }
		cell^ = i64(transmute(u32)f32(d))
	case 'F':
		d: f64
		if wj.JS_ToFloat64(ctx, &d, v) < 0 { return false }
		cell^ = transmute(i64)d
	case 'r':
		if wj.is_null(v) { cell^ = 0; return true }
		a := v
		r := wj.JS_Call(ctx, wr.func_id, wj.UNDEFINED, 1, &a)
		if wj.is_exception(r) { return false }
		defer wj.JS_FreeValue(ctx, r)
		if wj.is_undefined(r) { wj.JS_ThrowTypeError(ctx, "WebAssembly objects are opaque: a function reference must be null or an exported WebAssembly function"); return false }
		x: i32
		wj.JS_ToInt32(ctx, &x, r)
		cell^ = i64(x) + 1
	case 'e':
		if wj.is_null(v) { cell^ = 0; return true }
		a := v
		r := wj.JS_Call(ctx, wr.extern_id, wj.UNDEFINED, 1, &a)
		if wj.is_exception(r) { return false }
		defer wj.JS_FreeValue(ctx, r)
		x: i32
		wj.JS_ToInt32(ctx, &x, r)
		cell^ = i64(x)
	case:
		wj.JS_ThrowTypeError(ctx, "type incompatibility when transforming from/to JS")
		return false
	}
	return true
}

@(private = "file")
wasm_from_cell :: proc "contextless" (ctx: ^wj.Context, letter: u8, cell: i64) -> wj.JSValue {
	switch letter {
	case 'i': return wj.new_int32(i32(u32(cell)))
	case 'I': return wj.JS_NewBigInt64(ctx, cell)
	case 'f': return wj.new_float64(ctx, f64(transmute(f32)u32(cell)))
	case 'F': return wj.new_float64(ctx, transmute(f64)cell)
	case 'r':
		if cell == 0 { return wj.NULL }
		a := wj.new_int32(i32(cell - 1))
		return wj.JS_Call(ctx, wr.func_wrap, wj.UNDEFINED, 1, &a)
	case 'e':
		if cell == 0 { return wj.NULL }
		a := wj.new_int32(i32(cell))
		return wj.JS_Call(ctx, wr.extern_value, wj.UNDEFINED, 1, &a)
	}
	return wj.JS_ThrowTypeError(ctx, "type incompatibility when transforming from/to JS")
}

// The value a Global or a Table starts with when none is given.
@(private = "file")
wasm_cell_arg :: proc "contextless" (ctx: ^wj.Context, letter: u8, v: wj.JSValue, cell: ^i64) -> bool {
	if wj.is_undefined(v) && letter != 'e' {
		cell^ = 0
		return true
	}
	return wasm_to_cell(ctx, letter, v, cell)
}

@(private = "file")
letter_arg :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> u8 {
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, "") { return 0 }
	defer wj.wj_str_free(ctx, &s)
	return s.len == 1 ? s.ptr[0] : 0
}

@(private = "file")
int_arg :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, i: i32) -> i32 {
	x: i32
	wj.JS_ToInt32(ctx, &x, wj.arg(argc, argv, i))
	return x
}

@(private = "file")
i64_arg :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, i: i32) -> i64 {
	d: f64
	wj.JS_ToFloat64(ctx, &d, wj.arg(argc, argv, i))
	return i64(d)
}

// ---- memories ----

@(private = "file")
memory_read :: proc "contextless" (user: u64, offset: int, bytes: [^]u8, n: int) {
	wj.wr_WebAssembly_Memory_read(i32(user), i64(offset), bytes, u32(n))
}

@(private = "file")
memory_write :: proc "contextless" (user: u64, offset: int, bytes: [^]u8, n: int) {
	wj.wr_WebAssembly_Memory_write(i32(user), i64(offset), bytes, u32(n))
}

// memoryCreate(initial, maximum): a number. maximum -1: none.
@(private = "file")
wasm_memory_create :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	id := wj.wr_WebAssembly_Memory_create(i64_arg(ctx, argc, argv, 0), i64_arg(ctx, argc, argv, 1))
	if id < 0 { return wasm_throw(ctx, i64(id), "WebAssembly.Memory()") }
	return wj.new_int32(id)
}

@(private = "file")
wasm_memory_pages :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_float64(ctx, f64(wj.wr_WebAssembly_Memory_pages(int_arg(ctx, argc, argv, 0))))
}

// memoryBuffer(id): the ArrayBuffer of its bytes as they are now.
@(private = "file")
wasm_memory_buffer :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	id := int_arg(ctx, argc, argv, 0)
	pages := wj.wr_WebAssembly_Memory_pages(id)
	if pages < 0 { return wj.JS_ThrowTypeError(ctx, "not a memory") }
	if pages > 65535 { return wj.JS_ThrowRangeError(ctx, "the memory is too large for this engine's ArrayBuffer") }
	return wj.JS_NewArrayBufferHost(ctx, uint(pages) * 65536, memory_read, memory_write, u64(id))
}

@(private = "file")
wasm_memory_detach :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.JS_DetachArrayBufferHost(ctx, wj.arg(argc, argv, 0))
	return wj.UNDEFINED
}

@(private = "file")
wasm_memory_grow :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	prev := wj.wr_WebAssembly_Memory_grow(int_arg(ctx, argc, argv, 0), i64_arg(ctx, argc, argv, 1))
	if prev < 0 { return wasm_throw(ctx, prev, "WebAssembly.Memory.grow()") }
	return wj.new_float64(ctx, f64(prev))
}

// ---- tables ----

// tableCreate(letter, initial, maximum, init)
@(private = "file")
wasm_table_create :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	letter := letter_arg(ctx, wj.arg(argc, argv, 0))
	if letter == 0 { return wj.EXCEPTION }
	init: i64
	if !wasm_to_cell(ctx, letter, wj.arg(argc, argv, 3), &init) { return wj.EXCEPTION }
	s := [1]u8{letter}
	id := wj.wr_WebAssembly_Table_create(&s[0], 1, i64_arg(ctx, argc, argv, 1), i64_arg(ctx, argc, argv, 2), init)
	if id < 0 { return wasm_throw(ctx, i64(id), "WebAssembly.Table()") }
	return wj.new_int32(id)
}

@(private = "file")
wasm_table_letter :: proc "contextless" (table: i32) -> u8 {
	b: [4]u8
	n := wj.wr_WebAssembly_Table_element(table, &b[0], len(b))
	return n == 1 ? b[0] : 0
}

@(private = "file")
wasm_table_element :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b := [1]u8{wasm_table_letter(int_arg(ctx, argc, argv, 0))}
	return wj.JS_NewStringLen(ctx, &b[0], 1)
}

@(private = "file")
wasm_table_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_float64(ctx, f64(wj.wr_WebAssembly_Table_length(int_arg(ctx, argc, argv, 0))))
}

@(private = "file")
wasm_table_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	id := int_arg(ctx, argc, argv, 0)
	cell: i64
	st := wj.wr_WebAssembly_Table_get(id, i64_arg(ctx, argc, argv, 1), ([^]u8)(&cell), 8)
	if st < 0 { return wasm_throw(ctx, i64(st), "WebAssembly.Table.get()") }
	return wasm_from_cell(ctx, wasm_table_letter(id), cell)
}

// tableSet(id, index, value)
@(private = "file")
wasm_table_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	id := int_arg(ctx, argc, argv, 0)
	cell: i64
	if !wasm_to_cell(ctx, wasm_table_letter(id), wj.arg(argc, argv, 2), &cell) { return wj.EXCEPTION }
	st := wj.wr_WebAssembly_Table_set(id, i64_arg(ctx, argc, argv, 1), cell)
	if st < 0 { return wasm_throw(ctx, i64(st), "WebAssembly.Table.set()") }
	return wj.UNDEFINED
}

// tableGrow(id, delta, init)
@(private = "file")
wasm_table_grow :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	id := int_arg(ctx, argc, argv, 0)
	cell: i64
	if !wasm_to_cell(ctx, wasm_table_letter(id), wj.arg(argc, argv, 2), &cell) { return wj.EXCEPTION }
	prev := wj.wr_WebAssembly_Table_grow(id, i64_arg(ctx, argc, argv, 1), cell)
	if prev < 0 { return wasm_throw(ctx, prev, "WebAssembly.Table.grow()") }
	return wj.new_float64(ctx, f64(prev))
}

// ---- globals ----

// globalCreate(letter, mutable, value)
@(private = "file")
wasm_global_create :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	letter := letter_arg(ctx, wj.arg(argc, argv, 0))
	if letter == 0 { return wj.EXCEPTION }
	cell: i64
	if !wasm_cell_arg(ctx, letter, wj.arg(argc, argv, 2), &cell) { return wj.EXCEPTION }
	s := [1]u8{letter}
	id := wj.wr_WebAssembly_Global_create(&s[0], 1, wj.to_bool(ctx, wj.arg(argc, argv, 1)) ? 1 : 0, cell)
	if id < 0 { return wasm_throw(ctx, i64(id), "WebAssembly.Global()") }
	return wj.new_int32(id)
}

@(private = "file")
wasm_global_letter :: proc "contextless" (global: i32) -> (u8, bool) {
	b: [4]u8
	n := wj.wr_WebAssembly_Global_type(global, &b[0], len(b))
	return n >= 1 ? b[0] : 0, n == 2
}

// globalType(id): the value type's letter, then "m" when it can change
@(private = "file")
wasm_global_type :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: [4]u8
	n := wj.wr_WebAssembly_Global_type(int_arg(ctx, argc, argv, 0), &b[0], len(b))
	return wj.JS_NewStringLen(ctx, &b[0], uint(max(n, 0)))
}

@(private = "file")
wasm_global_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	id := int_arg(ctx, argc, argv, 0)
	letter, _ := wasm_global_letter(id)
	return wasm_from_cell(ctx, letter, wj.wr_WebAssembly_Global_get(id))
}

@(private = "file")
wasm_global_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	id := int_arg(ctx, argc, argv, 0)
	letter, mutable := wasm_global_letter(id)
	if !mutable { return wj.JS_ThrowTypeError(ctx, "set WebAssembly.Global.value: Can't set the value of an immutable global.") }
	cell: i64
	if !wasm_to_cell(ctx, letter, wj.arg(argc, argv, 1), &cell) { return wj.EXCEPTION }
	st := wj.wr_WebAssembly_Global_set(id, cell)
	if st < 0 { return wasm_throw(ctx, i64(st), "WebAssembly.Global.value") }
	return wj.UNDEFINED
}

// ---- functions ----

// A function's signature, kept by its number (a call reads it). nil with an exception when there is no such function.
@(private = "file")
wasm_sig_of :: proc "contextless" (ctx: ^wj.Context, id: i32) -> cstring {
	if id < 0 { wj.JS_ThrowTypeError(ctx, "not a function"); return nil }
	if id >= wr.sigs_cap {
		cap := max(id + 1, wr.sigs_cap * 2, 64)
		n := ([^]cstring)(wj.libc_realloc(wr.sigs, uint(cap) * size_of(cstring)))
		if n == nil { wj.JS_ThrowOutOfMemory(ctx); return nil }
		for i in wr.sigs_cap ..< cap { n[i] = nil }
		wr.sigs, wr.sigs_cap = n, cap
	}
	if wr.sigs[id] != nil { return wr.sigs[id] }
	n := wj.wr_WebAssembly_Func_sig(id, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(n)) { wj.JS_ThrowOutOfMemory(ctx); return nil }
		n = wj.wr_WebAssembly_Func_sig(id, wj.wj_scratch.data, wj.wj_scratch.cap)
	}
	if n <= 0 { wj.JS_ThrowTypeError(ctx, "not a function"); return nil }
	s := wj.web_strndup(wj.wj_scratch.data, uint(n))
	if s == nil { wj.JS_ThrowOutOfMemory(ctx); return nil }
	wr.sigs[id] = wj.cstr(s)
	return wr.sigs[id]
}

// A call of an exported function: `magic` is its number.
@(private = "file")
wasm_invoke :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, func_data: [^]wj.JSValue) -> wj.JSValue {
	sig := ([^]u8)(rawptr(wasm_sig_of(ctx, magic)))
	if sig == nil { return wj.EXCEPTION }
	np := 0
	for sig[np] != ':' { np += 1 }
	res := sig[np + 1:]
	nr := 0
	for res[nr] != 0 { nr += 1 }
	small: [SMALL_CELLS]i64
	cells := cells_of(small[:], max(np, nr))
	if cells == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer cells_free(small[:], cells)
	for i in 0 ..< np {
		if !wasm_to_cell(ctx, sig[i], wj.arg(argc, argv, i32(i)), &cells[i]) { return wj.EXCEPTION }
	}
	st := wj.wr_WebAssembly_Func_call(magic, ([^]u8)(cells), u32(np) * 8)
	if st < 0 { return wasm_throw(ctx, i64(st), "WebAssembly function") }
	if nr == 0 { return wj.UNDEFINED }
	wj.wr_WebAssembly_Func_results(([^]u8)(cells), u32(nr) * 8)
	if nr == 1 { return wasm_from_cell(ctx, res[0], cells[0]) }
	arr := wj.JS_NewArray(ctx)
	if wj.is_exception(arr) { return arr }
	for i in 0 ..< nr {
		v := wasm_from_cell(ctx, res[i], cells[i])
		if wj.is_exception(v) || wj.JS_DefinePropertyValueUint32(ctx, arr, u32(i), v, wj.PROP_C_W_E) < 0 {
			wj.JS_FreeValue(ctx, arr)
			return wj.EXCEPTION
		}
	}
	return arr
}

// funcWrap(id, name): the function object of a number.
@(private = "file")
wasm_func_wrap :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	id := int_arg(ctx, argc, argv, 0)
	sig := ([^]u8)(rawptr(wasm_sig_of(ctx, id)))
	if sig == nil { return wj.EXCEPTION }
	np: i32
	for sig[np] != ':' { np += 1 }
	name: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &name, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	return wj.JS_NewCFunctionData2(ctx, wasm_invoke, wj.cstr(name.ptr), np, id, 0, nil)
}

// importFunc(fn, sig): the number of a function of that signature that calls `fn`.
@(private = "file")
wasm_import_func :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &s, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	if wr.imports_n == wr.imports_cap {
		cap := max(wr.imports_cap * 2, 64)
		n := ([^]Wasm_Import)(wj.libc_realloc(wr.imports, uint(cap) * size_of(Wasm_Import)))
		if n == nil { return wj.JS_ThrowOutOfMemory(ctx) }
		wr.imports, wr.imports_cap = n, cap
	}
	slot := wr.imports_n
	id := wj.wr_WebAssembly_Func_import(slot, s.ptr, u32(s.len))
	if id < 0 { return wasm_throw(ctx, i64(id), "WebAssembly.Instance()") }
	sig := wj.web_strndup(s.ptr, s.len)
	if sig == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	wr.imports[slot] = Wasm_Import{fn = wj.JS_DupValue(ctx, wj.arg(argc, argv, 0)), sig = wj.cstr(sig)}
	wr.imports_n += 1
	return wj.new_int32(id)
}

// The module calls import `slot`. 0 when it went well, else what it threw waits in wr.pending for wasm_throw.
@(export, link_name = "wj_wasm_import")
wj_wasm_import :: proc "c" (slot: i32) -> i32 {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if slot < 0 || slot >= wr.imports_n { return 1 }
	im := wr.imports[slot]
	sig := ([^]u8)(rawptr(im.sig))
	np := 0
	for sig[np] != ':' { np += 1 }
	small: [SMALL_CELLS]i64
	cells := cells_of(small[:], np)
	small_args: [SMALL_CELLS]wj.JSValue
	args := np <= SMALL_CELLS ? ([^]wj.JSValue)(&small_args[0]) : ([^]wj.JSValue)(wj.libc_malloc(uint(np) * size_of(wj.JSValue)))
	defer {
		cells_free(small[:], cells)
		if np > SMALL_CELLS { wj.libc_free(args) }
	}
	made := 0
	failed := cells == nil || args == nil
	if failed { wj.JS_ThrowOutOfMemory(ctx) } else if np > 0 { wj.wr_WebAssembly_import_args(([^]u8)(cells), u32(np) * 8) }
	if !failed {
		for i in 0 ..< np {
			args[i] = wasm_from_cell(ctx, sig[i], cells[i])
			if wj.is_exception(args[i]) { failed = true; break }
			made += 1
		}
	}
	r := failed ? wj.EXCEPTION : wj.JS_Call(ctx, im.fn, wj.UNDEFINED, i32(np), args)
	for i in 0 ..< made { wj.JS_FreeValue(ctx, args[i]) }
	if !wj.is_exception(r) {
		ok := wasm_import_results(ctx, sig[np + 1:], r)
		wj.JS_FreeValue(ctx, r)
		if ok { return 0 }
	}
	e := wj.JS_GetException(ctx)
	// (any exception the module can catch; only the one that stops the script goes through it, as a trap)
	if !wj.JS_IsUncatchableError(e) && wasm_import_threw(ctx, e) {
		wj.JS_FreeValue(ctx, e)
		return 1
	}
	if wr.has_pending { wj.JS_FreeValue(ctx, wr.pending) }
	wr.pending = e
	wr.has_pending = true
	msg := "an import threw an exception"
	wj.wr_WebAssembly_import_failed(raw_data(msg), u32(len(msg)))
	return 1
}

// What the import returned, converted to its results: false with an exception.
@(private = "file")
wasm_import_results :: proc "contextless" (ctx: ^wj.Context, res: [^]u8, r: wj.JSValue) -> bool {
	nr := 0
	for res[nr] != 0 { nr += 1 }
	if nr == 0 { return true }
	small: [SMALL_CELLS]i64
	cells := cells_of(small[:], nr)
	if cells == nil { wj.JS_ThrowOutOfMemory(ctx); return false }
	defer cells_free(small[:], cells)
	if nr == 1 {
		if !wasm_to_cell(ctx, res[0], r, &cells[0]) { return false }
	} else {
		a := r
		list := wj.JS_Call(ctx, wr.to_list, wj.UNDEFINED, 1, &a)
		if wj.is_exception(list) { return false }
		defer wj.JS_FreeValue(ctx, list)
		n: i64
		wj.JS_GetLength(ctx, list, &n)
		if n != i64(nr) { wj.JS_ThrowTypeError(ctx, "multi-return length mismatch"); return false }
		for i in 0 ..< nr {
			v := wj.JS_GetPropertyUint32(ctx, list, u32(i))
			if wj.is_exception(v) { return false }
			ok := wasm_to_cell(ctx, res[i], v, &cells[i])
			wj.JS_FreeValue(ctx, v)
			if !ok { return false }
		}
	}
	wj.wr_WebAssembly_import_results(([^]u8)(cells), u32(nr) * 8)
	return true
}

// ---- instances ----

// instanceCreate(moduleHandle, ids): a number. `ids` an array of the numbers of what it imports.
@(private = "file")
wasm_instance_create :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	module := wasm_handle_of(wj.arg(argc, argv, 0))
	ids := wj.arg(argc, argv, 1)
	n: i64
	if wj.JS_GetLength(ctx, ids, &n) < 0 { return wj.EXCEPTION }
	list := ([^]u32)(wj.libc_malloc(uint(max(n, 1)) * 4))
	if list == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer wj.libc_free(list)
	for i in 0 ..< n {
		v := wj.JS_GetPropertyUint32(ctx, ids, u32(i))
		x: i32
		wj.JS_ToInt32(ctx, &x, v)
		wj.JS_FreeValue(ctx, v)
		list[i] = u32(x)
	}
	id := wj.wr_WebAssembly_Instance_create(module, ([^]u8)(list), u32(n) * 4)
	if id < 0 { return wasm_throw(ctx, i64(id), "WebAssembly.Instance()") }
	return wj.new_int32(id)
}

// instanceExports(id, moduleHandle): [{name, kind, id, index}]
@(private = "file")
wasm_instance_exports :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wasm_described(ctx, wasm_handle_of(wj.arg(argc, argv, 1)), int_arg(ctx, argc, argv, 0), proc "contextless" (m: u64, id: i32, buf: [^]u8, cap: u32) -> i32 { return wj.wr_WebAssembly_Instance_exports(id, m, buf, cap) })
}

// tagCreate(parameters): a number
@(private = "file")
wasm_tag_create :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &s, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &s)
	id := wj.wr_WebAssembly_Tag_create(s.ptr != nil ? s.ptr : wj.empty_ptr(), u32(s.len))
	if id < 0 { return wasm_throw(ctx, i64(id), "WebAssembly.Tag()") }
	return wj.new_int32(id)
}

// tagSig(id): its parameters, one letter each
@(private = "file")
wasm_tag_sig :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	sig: [MAX_TAG_VALUES + 1]u8
	n := wj.wr_WebAssembly_Tag_sig(int_arg(ctx, argc, argv, 0), &sig[0], MAX_TAG_VALUES)
	return wj.JS_NewStringLen(ctx, &sig[0], uint(clamp(n, 0, MAX_TAG_VALUES)))
}

// setup({LinkError, RuntimeError, funcId, funcWrap, externId, externValue, toList, exceptionMake, exceptionInfo})
@(private = "file")
wasm_setup :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	o := wj.arg(argc, argv, 0)
	wr.link_error = wj.JS_GetPropertyStr(ctx, o, "LinkError")
	wr.runtime_error = wj.JS_GetPropertyStr(ctx, o, "RuntimeError")
	wr.func_id = wj.JS_GetPropertyStr(ctx, o, "funcId")
	wr.func_wrap = wj.JS_GetPropertyStr(ctx, o, "funcWrap")
	wr.extern_id = wj.JS_GetPropertyStr(ctx, o, "externId")
	wr.extern_value = wj.JS_GetPropertyStr(ctx, o, "externValue")
	wr.to_list = wj.JS_GetPropertyStr(ctx, o, "toList")
	wr.exception_make = wj.JS_GetPropertyStr(ctx, o, "exceptionMake")
	wr.exception_info = wj.JS_GetPropertyStr(ctx, o, "exceptionInfo")
	return wj.UNDEFINED
}

// The realm's `WebAssembly`, made on first use: a page that never looks at it pays nothing.
@(export, link_name = "web_wasm_start")
web_wasm_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	if wj.wr_WebAssembly_enabled() == 0 { return 0 }
	a := wj.JS_NewAtom(ctx, "WebAssembly")
	defer wj.JS_FreeAtom(ctx, a)
	return wj.JS_DefineHostAutoInitProperty(ctx, wj.wj_the_realm.global, a, wasm_autoinit, wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE) < 0 ? -1 : 0
}

@(private = "file")
wasm_autoinit :: proc "c" (ctx: ^wj.Context, atom: wj.Atom) -> wj.JSValue {
	if wasm_handle_class == 0 {
		rt := wj.JS_GetRuntime(ctx)
		wj.JS_NewClassID(rt, &wasm_handle_class)
		def := wj.Class_Def{class_name = "WebAssemblyHandle", finalizer = wasm_handle_finalizer}
		if wj.JS_NewClass(rt, wasm_handle_class, &def) < 0 { wasm_handle_class = 0; return wj.JS_ThrowOutOfMemory(ctx) }
	}
	fn := eval_prelude(ctx, "web_wasm.js", #load("web_wasm.js"))
	if wj.is_exception(fn) { return fn }
	defer wj.JS_FreeValue(ctx, fn)
	native := wj.JS_NewObject(ctx)
	defer wj.JS_FreeValue(ctx, native)
	Entry :: struct { name: cstring, fn: wj.Native, length: i32 }
	entries := [?]Entry{
		{"setup", wasm_setup, 1},
		{"validate", wasm_validate, 1},
		{"compile", wasm_compile, 1},
		{"compileAsync", wasm_compile_async, 2},
		{"imports", wasm_imports, 1},
		{"exports", wasm_exports, 1},
		{"customSections", wasm_custom_sections, 2},
		{"linkInfo", wasm_link_info, 1},
		{"memoryCreate", wasm_memory_create, 2},
		{"memoryPages", wasm_memory_pages, 1},
		{"memoryBuffer", wasm_memory_buffer, 1},
		{"memoryDetach", wasm_memory_detach, 1},
		{"memoryGrow", wasm_memory_grow, 2},
		{"tableCreate", wasm_table_create, 4},
		{"tableElement", wasm_table_element, 1},
		{"tableLength", wasm_table_length, 1},
		{"tableGet", wasm_table_get, 2},
		{"tableSet", wasm_table_set, 3},
		{"tableGrow", wasm_table_grow, 3},
		{"globalCreate", wasm_global_create, 3},
		{"globalType", wasm_global_type, 1},
		{"globalGet", wasm_global_get, 1},
		{"globalSet", wasm_global_set, 2},
		{"funcWrap", wasm_func_wrap, 2},
		{"importFunc", wasm_import_func, 2},
		{"externReleased", wasm_extern_released, 0},
		{"tagCreate", wasm_tag_create, 1},
		{"tagSig", wasm_tag_sig, 1},
		{"instanceCreate", wasm_instance_create, 2},
		{"instanceExports", wasm_instance_exports, 2},
	}
	for &e in entries {
		wj.JS_DefinePropertyValueStr(ctx, native, e.name, wj.new_cfunction(ctx, e.fn, e.name, e.length), wj.PROP_C_W_E)
	}
	args := [2]wj.JSValue{native, wj.wj_the_realm.global}
	return wj.JS_Call(ctx, fn, wj.UNDEFINED, 2, &args[0])
}

@(private = "file")
cells_of :: proc "contextless" (small: []i64, n: int) -> [^]i64 {
	return n <= len(small) ? raw_data(small) : ([^]i64)(wj.libc_malloc(uint(n) * size_of(i64)))
}

@(private = "file")
cells_free :: proc "contextless" (small: []i64, cells: [^]i64) {
	if cells != raw_data(small) { wj.libc_free(cells) }
}

// externReleased(): the number of an externref no reference is left to; 0 when there is none
@(private = "file")
wasm_extern_released :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_int32(wj.wr_WebAssembly_extern_released())
}
