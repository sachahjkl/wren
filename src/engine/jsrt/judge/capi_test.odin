package jsrt_judge

// judge capi: exercises the QuickJS C API on jsrt (src/engine/jscapi) the way Wren's glue uses it: owned and
// borrowed references, classes with opaque data, finalizers and gc_mark (cycles through opaque data), exotic
// objects, native functions, exceptions, promises and jobs, array buffers, native modules.
//
// A JSValue holds a 32-bit pointer, so the engine runs on a heap below 4 GiB: a TLSF arena over memory
// reserved at a low address.

import "base:runtime"
import "core:fmt"
import "core:mem/tlsf"
import "core:strings"
import "core:sys/windows"
import capi "wb:engine/jscapi"

@(private = "file") checks, fails: int
@(private = "file") finalized, freed_buffers: int
@(private = "file") cls_point, cls_virt: capi.Class_ID
@(private = "file") point_proto: capi.JSValue

@(private = "file")
check :: proc(ok: bool, what: string) {
	checks += 1
	if !ok {
		fails += 1
		fmt.eprintln("FAIL:", what)
	}
}

@(private = "file")
Point :: struct {
	x:    i32,
	held: capi.JSValue,
}

@(private = "file")
point_finalizer :: proc "c" (rt: ^capi.Runtime, val: capi.JSValue) {
	context = runtime.default_context()
	p := cast(^Point)capi.JS_GetOpaque(val, cls_point)
	finalized += 1
	if p != nil {
		capi.JS_FreeValueRT(rt, p.held)
		free(p)
	}
}

@(private = "file")
point_gc_mark :: proc "c" (rt: ^capi.Runtime, val: capi.JSValue, mark: capi.Mark_Func) {
	p := cast(^Point)capi.JS_GetOpaque(val, cls_point)
	if p != nil {capi.JS_MarkValue(rt, p.held, mark)}
}

// mk(x): a Point.
@(private = "file")
mk_point :: proc "c" (ctx: ^capi.Context, this: capi.JSValue, argc: i32, argv: [^]capi.JSValue) -> capi.JSValue {
	context = runtime.default_context()
	o := capi.JS_NewObjectProtoClass(ctx, point_proto, cls_point)
	p := new(Point)
	p.held = capi.UNDEFINED
	if argc > 0 {
		x: i32
		capi.JS_ToInt32(ctx, &x, argv[0])
		p.x = x
	}
	capi.JS_SetOpaque(o, p)
	return o
}

// hold(point, value): the point keeps a counted reference to value.
@(private = "file")
hold_value :: proc "c" (ctx: ^capi.Context, this: capi.JSValue, argc: i32, argv: [^]capi.JSValue) -> capi.JSValue {
	p := cast(^Point)capi.JS_GetOpaque(argv[0], cls_point)
	if p == nil {return capi.JS_ThrowTypeError(ctx, "not a Point")}
	capi.JS_FreeValue(ctx, p.held)
	p.held = capi.JS_DupValue(ctx, argv[1])
	return capi.UNDEFINED
}

@(private = "file")
point_x :: proc "c" (ctx: ^capi.Context, this: capi.JSValue) -> capi.JSValue {
	p := cast(^Point)capi.JS_GetOpaque(this, cls_point)
	if p == nil {return capi.JS_ThrowTypeError(ctx, "not a Point")}
	return capi.mkval(capi.TAG_INT, u32(p.x))
}

@(private = "file")
add3 :: proc "c" (ctx: ^capi.Context, this: capi.JSValue, argc: i32, argv: [^]capi.JSValue, magic: i32, data: [^]capi.JSValue) -> capi.JSValue {
	a, b: i32
	capi.JS_ToInt32(ctx, &a, argv[0])
	capi.JS_ToInt32(ctx, &b, data[0])
	return capi.mkval(capi.TAG_INT, u32(a + b + magic))
}

@(private = "file")
thrower :: proc "c" (ctx: ^capi.Context, this: capi.JSValue, argc: i32, argv: [^]capi.JSValue) -> capi.JSValue {
	return capi.JS_ThrowTypeError(ctx, "bad %s %d", cstring("thing"), i32(7))
}

// An exotic class: every property reads as its own name, own keys are "a" and "b".
@(private = "file")
virt_get :: proc "c" (ctx: ^capi.Context, obj: capi.JSValue, prop: capi.Atom, receiver: capi.JSValue) -> capi.JSValue {
	name := capi.JS_AtomToString(ctx, prop)
	return name
}

@(private = "file")
virt_has :: proc "c" (ctx: ^capi.Context, obj: capi.JSValue, prop: capi.Atom) -> i32 {
	return 1
}

@(private = "file")
virt_names :: proc "c" (ctx: ^capi.Context, ptab: ^[^]capi.Property_Enum, plen: ^u32, obj: capi.JSValue) -> i32 {
	context = runtime.default_context()
	tab := make([]capi.Property_Enum, 2, capi.host_allocator)
	tab[0] = {true, capi.JS_NewAtom(ctx, "a")}
	tab[1] = {true, capi.JS_NewAtom(ctx, "b")}
	ptab^ = raw_data(tab)
	plen^ = 2
	return 0
}

@(private = "file")
virt_own :: proc "c" (ctx: ^capi.Context, desc: ^capi.Property_Descriptor, obj: capi.JSValue, prop: capi.Atom) -> i32 {
	n := capi.JS_AtomToString(ctx, prop)
	cs := capi.JS_ToCString(ctx, n)
	ok := cs == "a" || cs == "b"
	capi.JS_FreeCString(ctx, cs)
	capi.JS_FreeValue(ctx, n)
	if !ok {return 0}
	if desc != nil {
		desc^ = {flags = capi.PROP_ENUMERABLE | capi.PROP_CONFIGURABLE, value = capi.mkval(capi.TAG_INT, 5), getter = capi.UNDEFINED, setter = capi.UNDEFINED}
	}
	return 1
}

@(private = "file")
buffer_free :: proc "c" (rt: ^capi.Runtime, opaque: rawptr, ptr: rawptr, size: uint) -> rawptr {
	if size == 0 {
		freed_buffers += 1
		context = runtime.default_context()
		free(ptr)
	}
	return nil
}

@(private = "file")
module_init :: proc "c" (ctx: ^capi.Context, m: ^capi.Module_Def) -> i32 {
	return capi.JS_SetModuleExport(ctx, m, "x", capi.mkval(capi.TAG_INT, 42))
}

@(private = "file")
native_module: ^capi.Module_Def

@(private = "file")
module_loader :: proc "c" (ctx: ^capi.Context, name: cstring, opaque: rawptr, attributes: capi.JSValue) -> ^capi.Module_Def {
	if name == "native:m" {
		if native_module == nil {
			native_module = capi.JS_NewCModule(ctx, "native:m", module_init)
			capi.JS_AddModuleExport(ctx, native_module, "x")
		}
		return native_module
	}
	capi.JS_ThrowReferenceError(ctx, "no module %s", name)
	return nil
}

@(private = "file")
eval :: proc(ctx: ^capi.Context, src: string, flags: i32 = 0) -> capi.JSValue {
	return capi.JS_Eval(ctx, raw_data(src), uint(len(src)), "capi.js", flags)
}

// A JS value as an Odin string (and the reference dropped).
@(private = "file")
text :: proc(ctx: ^capi.Context, v: capi.JSValue) -> string {
	cs := capi.JS_ToCString(ctx, v)
	s := strings.clone(string(cs))
	capi.JS_FreeCString(ctx, cs)
	capi.JS_FreeValue(ctx, v)
	return s
}

@(private = "file")
int_of :: proc(v: capi.JSValue) -> i32 {return i32(u32(v))}

@(private = "file")
is_int :: proc(v: capi.JSValue, n: i32) -> bool {return capi.tag_of(v) == capi.TAG_INT && int_of(v) == n}

@(private = "file")
run_jobs :: proc(rt: ^capi.Runtime) {
	pc: ^capi.Context
	for capi.JS_ExecutePendingJob(rt, &pc) > 0 {}
}

capi_main :: proc() -> int {
	// an arena below 4 GiB
	arena: []u8
	for addr in ([]uintptr{0x10000000, 0x20000000, 0x30000000, 0x40000000, 0x50000000}) {
		p := windows.VirtualAlloc(rawptr(addr), 1 << 28, windows.MEM_RESERVE | windows.MEM_COMMIT, windows.PAGE_READWRITE)
		if p != nil && uintptr(p) + (1 << 28) <= 0x100000000 {
			arena = ([^]u8)(p)[:1 << 28]
			break
		}
	}
	if arena == nil {
		fmt.eprintln("capi: cannot reserve memory below 4 GiB")
		return 2
	}
	t: tlsf.Allocator
	_ = tlsf.init_from_buffer(&t, arena)
	capi.host_allocator = tlsf.allocator(&t)

	rt := capi.JS_NewRuntime()
	ctx := capi.JS_NewContext(rt)
	global := capi.JS_GetGlobalObject(ctx)

	// --- values, strings, evaluation ---
	v := eval(ctx, "1 + 2")
	check(is_int(v, 3), "eval 1+2")
	v = eval(ctx, "0.5 + 0.25")
	check(capi.tag_of(v) >= capi.TAG_FLOAT64 || capi.tag_of(v) < capi.TAG_FIRST, "float has a float tag")
	f: f64
	capi.JS_ToFloat64(ctx, &f, v)
	check(f == 0.75, "float round trip")
	check(text(ctx, eval(ctx, "'caf\\u00e9 ' + 'x'.repeat(3)")) == "café xxx", "string with latin-1 and ascii")
	check(text(ctx, eval(ctx, "'\\ud83d\\ude00'")) == "😀", "surrogate pair as UTF-8")
	check(text(ctx, eval(ctx, "[1,2,3].map(x => x * 2).join('-')")) == "2-4-6", "array map/join")
	ex := eval(ctx, "throw new RangeError('boom')")
	check(capi.tag_of(ex) == capi.TAG_EXCEPTION, "throw yields the exception tag")
	e := capi.JS_GetException(ctx)
	check(text(ctx, capi.JS_GetPropertyStr(ctx, e, "message")) == "boom", "exception message")
	capi.JS_FreeValue(ctx, e)
	check(!capi.JS_HasException(ctx), "exception taken")

	// --- properties ---
	o := capi.JS_NewObject(ctx)
	capi.JS_SetPropertyStr(ctx, o, "a", capi.mkval(capi.TAG_INT, 5))
	capi.JS_SetPropertyStr(ctx, o, "s", capi.JS_NewString(ctx, "hi"))
	capi.JS_SetPropertyUint32(ctx, o, 3, capi.TRUE)
	check(is_int(capi.JS_GetPropertyStr(ctx, o, "a"), 5), "get/set int property")
	check(text(ctx, capi.JS_GetPropertyStr(ctx, o, "s")) == "hi", "get/set string property")
	check(capi.JS_GetPropertyUint32(ctx, o, 3) == capi.TRUE, "index property")
	tab: [^]capi.Property_Enum
	n: u32
	check(capi.JS_GetOwnPropertyNames(ctx, &tab, &n, o, capi.GPN_STRING_MASK | capi.GPN_ENUM_ONLY) == 0 && n == 3, "own property names")
	capi.JS_FreePropertyEnum(ctx, tab, n)
	capi.JS_SetPropertyStr(ctx, global, "o", capi.JS_DupValue(ctx, o))
	check(text(ctx, eval(ctx, "Object.keys(o).join()")) == "3,a,s", "keys through the API")
	capi.JS_FreeValue(ctx, o)

	// --- native functions, closures with data, exceptions ---
	capi.JS_SetPropertyStr(ctx, global, "thrower", capi.JS_NewCFunction2(ctx, thrower, "thrower", 0, capi.CFUNC_generic, 0))
	check(text(ctx, eval(ctx, "try { thrower() } catch (e) { e.name + ':' + e.message }")) == "TypeError:bad thing 7", "formatted TypeError from C")
	data := [1]capi.JSValue{capi.mkval(capi.TAG_INT, 10)}
	capi.JS_SetPropertyStr(ctx, global, "add3", capi.JS_NewCFunctionData(ctx, add3, 1, 100, 1, raw_data(data[:])))
	check(is_int(eval(ctx, "add3(5)"), 115), "C function with data and magic")
	fn := eval(ctx, "(function (a, b) { return a * b })")
	args := [2]capi.JSValue{capi.mkval(capi.TAG_INT, 6), capi.mkval(capi.TAG_INT, 7)}
	check(is_int(capi.JS_Call(ctx, fn, capi.UNDEFINED, 2, raw_data(args[:])), 42), "JS_Call of a script function")
	capi.JS_FreeValue(ctx, fn)

	// --- classes: opaque data, finalizer, cycles through gc_mark ---
	capi.JS_NewClassID(rt, &cls_point)
	cdef := capi.Class_Def{class_name = "Point", finalizer = point_finalizer, gc_mark = point_gc_mark}
	check(capi.JS_NewClass(rt, cls_point, &cdef) == 0, "JS_NewClass")
	point_proto = capi.JS_NewObject(ctx)
	capi.JS_DefinePropertyGetSet(ctx, point_proto, capi.JS_NewAtom(ctx, "x"), capi.JS_NewCFunction2(ctx, cast(capi.Native)point_x, "x", 0, capi.CFUNC_getter, 0), capi.UNDEFINED, capi.PROP_CONFIGURABLE)
	capi.JS_SetPropertyStr(ctx, global, "mk", capi.JS_NewCFunction2(ctx, mk_point, "mk", 1, capi.CFUNC_generic, 0))
	capi.JS_SetPropertyStr(ctx, global, "hold", capi.JS_NewCFunction2(ctx, hold_value, "hold", 2, capi.CFUNC_generic, 0))
	check(is_int(eval(ctx, "mk(9).x"), 9), "getter reads the opaque data")
	capi.JS_RunGC(rt)
	base := finalized
	r := eval(ctx, "for (var i = 0; i < 1000; i++) { (function () { var p = mk(i); hold(p, function () { return p; }); })(); } 0")
	check(is_int(r, 0), "create 1000 points held in cycles")
	capi.JS_RunGC(rt)
	check(finalized - base == 1000, fmt.tprintf("cycles through opaque data are collected (%d of 1000)", finalized - base))
	base = finalized
	eval(ctx, "globalThis.keep = mk(1); hold(keep, function () { return keep; }); 0")
	capi.JS_RunGC(rt)
	check(finalized == base, "a reachable point is kept")
	check(is_int(eval(ctx, "keep.x"), 1), "and still works")
	eval(ctx, "keep = null; 0")
	capi.JS_RunGC(rt)
	check(finalized == base + 1, "dropped, then collected")

	// a counted reference keeps an object alive; freeing it releases it
	base = finalized
	p1 := capi.JS_NewObjectProtoClass(ctx, point_proto, cls_point)
	capi.JS_SetOpaque(p1, new(Point))
	(cast(^Point)capi.JS_GetOpaque(p1, cls_point)).held = capi.UNDEFINED
	extra := capi.JS_DupValue(ctx, p1)
	capi.JS_FreeValue(ctx, p1)
	capi.JS_RunGC(rt)
	check(finalized == base, "a Dup'd reference is a root")
	capi.JS_FreeValue(ctx, extra)
	capi.JS_RunGC(rt)
	check(finalized == base + 1, "freed reference, collected")

	// --- exotic objects ---
	capi.JS_NewClassID(rt, &cls_virt)
	ex_methods := capi.Class_Exotic_Methods {
		get_property           = virt_get,
		has_property           = virt_has,
		get_own_property_names = virt_names,
		get_own_property       = virt_own,
	}
	vdef := capi.Class_Def{class_name = "Virt", exotic = &ex_methods}
	capi.JS_NewClass(rt, cls_virt, &vdef)
	capi.JS_SetPropertyStr(ctx, global, "virt", capi.JS_NewObjectProtoClass(ctx, capi.NULL, cls_virt))
	check(text(ctx, eval(ctx, "virt.hello")) == "hello", "exotic get_property")
	check(text(ctx, eval(ctx, "'zzz' in virt")) == "true", "exotic has_property")
	check(text(ctx, eval(ctx, "Object.getOwnPropertyNames(virt).join()")) == "a,b", "exotic own names")
	check(text(ctx, eval(ctx, "Object.keys(virt).join()")) == "a,b", "exotic enumerable own properties")

	// --- promises and jobs ---
	funcs: [2]capi.JSValue
	pr := capi.JS_NewPromiseCapability(ctx, raw_data(funcs[:]))
	capi.JS_SetPropertyStr(ctx, global, "pr", capi.JS_DupValue(ctx, pr))
	eval(ctx, "globalThis.got = 0; pr.then(v => { got = v * 2; }); 0")
	one := [1]capi.JSValue{capi.mkval(capi.TAG_INT, 21)}
	capi.JS_FreeValue(ctx, capi.JS_Call(ctx, funcs[0], capi.UNDEFINED, 1, raw_data(one[:])))
	check(capi.JS_PromiseState(ctx, pr) == .Fulfilled, "promise fulfilled through the resolving function")
	run_jobs(rt)
	check(is_int(eval(ctx, "got"), 42), "then reaction ran as a job")
	capi.JS_FreeValue(ctx, funcs[0])
	capi.JS_FreeValue(ctx, funcs[1])
	capi.JS_FreeValue(ctx, pr)

	// --- array buffers ---
	raw := make([]u8, 16)
	raw[3] = 9
	ab := capi.JS_NewArrayBuffer(ctx, raw_data(raw), 16, max(uint), buffer_free, nil, false)
	capi.JS_SetPropertyStr(ctx, global, "ab", ab)
	check(is_int(eval(ctx, "new Uint8Array(ab)[3]"), 9), "adopted buffer is readable")
	eval(ctx, "ab = null; 0")
	capi.JS_RunGC(rt)
	check(freed_buffers == 1, "adopted buffer released on collection")
	ta := capi.JS_NewUint8ArrayCopy(ctx, raw_data([]u8{1, 2, 3}), 3)
	capi.JS_SetPropertyStr(ctx, global, "ta", ta)
	check(is_int(eval(ctx, "ta.length + ta[2]"), 6), "Uint8Array copy")

	// --- a native module imported by a script module ---
	capi.JS_SetModuleLoaderFunc2(rt, nil, module_loader, nil, nil)
	pm := eval(ctx, "import { x } from 'native:m'; globalThis.fromModule = x + 1;", capi.EVAL_TYPE_MODULE)
	check(capi.tag_of(pm) != capi.TAG_EXCEPTION, "module with a native import evaluates")
	run_jobs(rt)
	check(is_int(eval(ctx, "fromModule"), 43), "native module export")
	capi.JS_FreeValue(ctx, pm)

	// --- a compiled function written out and read back (the realm snapshot of the glue) ---
	code := "globalThis.viaImage = 7 * 6;"
	fnv := capi.JS_Eval(ctx, raw_data(code), uint(len(code)), "img.js", capi.EVAL_FLAG_COMPILE_ONLY)
	size: uint
	img := capi.JS_WriteObject(ctx, &size, fnv, capi.WRITE_OBJ_BYTECODE)
	check(img != nil && size > 0, "JS_WriteObject of a compiled function")
	fn2 := capi.JS_ReadObject(ctx, img, size, capi.READ_OBJ_BYTECODE)
	capi.JS_FreeValue(ctx, capi.JS_EvalFunction(ctx, fn2))
	check(is_int(eval(ctx, "viaImage"), 42), "the image runs")
	capi.js_free(ctx, img)
	capi.JS_FreeValue(ctx, fnv)

	// --- soak: many temporaries through the API, GC in between ---
	for i in 0 ..< 20000 {
		a := capi.JS_NewObject(ctx)
		s := capi.JS_NewString(ctx, "temp")
		capi.JS_SetPropertyStr(ctx, a, "s", s)
		arr := capi.JS_NewArray(ctx)
		capi.JS_SetPropertyUint32(ctx, arr, 0, a)
		capi.JS_FreeValue(ctx, arr)
		if i % 5000 == 0 {capi.JS_RunGC(rt)}
	}
	capi.JS_RunGC(rt)
	st: capi.Memory_Usage
	capi.JS_ComputeMemoryUsage(rt, &st)
	check(st.malloc_size < 32 << 20, fmt.tprintf("temporaries are collected (heap %d KiB)", st.malloc_size / 1024))

	capi.JS_FreeValue(ctx, point_proto)
	capi.JS_FreeValue(ctx, global)
	capi.JS_FreeContext(ctx)
	capi.JS_FreeRuntime(rt)
	fmt.printfln("capi: %d checks, %d failures", checks, fails)
	return fails == 0 ? 0 : 1
}
