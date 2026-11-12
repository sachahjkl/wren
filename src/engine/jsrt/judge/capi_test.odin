package jsrt_judge

// judge capi: exercises the QuickJS C API on jsrt (src/engine/jscapi) the way Wren's glue uses it: owned and
// borrowed references, classes with opaque data, finalizers and gc_mark (cycles through opaque data), exotic
// objects, native functions, exceptions, promises and jobs, array buffers, native modules.
//
// A JSValue holds a 32-bit pointer, so the engine runs on a heap below 4 GiB: a TLSF arena over memory
// reserved at a low address.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/tlsf"
import "core:strings"
import capi "wb:engine/jscapi"
import js "wb:engine/jsrt"

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

@(private = "file") epilogues, finalized_at_epilogue: int

@(private = "file")
count_epilogue :: proc "c" (rt: ^capi.Runtime, opaque: rawptr) {
	epilogues += 1
	finalized_at_epilogue = finalized
}

// A class whose Point is the object's payload (JS_NewObjectProtoClassPayload): its finalizer drops the reference the
// payload holds and frees nothing else.
@(private = "file") cls_pod: capi.Class_ID
@(private = "file") pods_finalized: int
@(private = "file") pod_marks: int   // calls of its gc_mark
@(private = "file") PODS_SOAK :: 10000

@(private = "file")
pod_finalizer :: proc "c" (rt: ^capi.Runtime, val: capi.JSValue) {
	p := cast(^Point)capi.JS_GetOpaque(val, cls_pod)
	pods_finalized += 1
	if p != nil {capi.JS_FreeValueRT(rt, p.held)}
}

@(private = "file")
pod_gc_mark :: proc "c" (rt: ^capi.Runtime, val: capi.JSValue, mark: capi.Mark_Func) {
	pod_marks += 1
	p := cast(^Point)capi.JS_GetOpaque(val, cls_pod)
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

// The bytes of a SharedArrayBuffer the embedder holds, which another agent writes too.
@(private = "file") shared_bytes: [8]u8

@(private = "file")
shared_read :: proc "contextless" (user: u64, offset: int, dst: [^]u8, n: int) {
	for i in 0 ..< n {dst[i] = shared_bytes[offset + i]}
}

@(private = "file")
shared_write :: proc "contextless" (user: u64, offset: int, src: [^]u8, n: int) {
	for i in 0 ..< n {shared_bytes[offset + i] = src[i]}
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
		p := low_memory_reserve(addr, 1 << 28)   // capi_arena_*.odin
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
	// the weak transitions of a shape (gc_sweep, from the shapes the marking listed): the dead ones go, the live ones stay
	eval(ctx, "globalThis.keep = {}; keep.live = 1; for (var i = 0; i < 2000; i++) { var o = {}; o['dead' + i] = i; o = null; }")
	capi.JS_RunGC(rt)
	check(is_int(eval(ctx, "var q = {}; q.dead7 = 3; q.live = 4; var r = {}; r.live = 5; Object.keys(q).length * 10 + Object.keys(r).length"), 21), "a transition after a collection that dropped others")
	// weak atoms: the keys made at run time and dropped go at the next collection and their slots are used again; a key
	// that a live object, a registered symbol, a for-in or the host holds stays
	rtj := cast(^js.Runtime)rt
	eval(ctx, "globalThis.kept = {}; kept['kept' + 7] = 7; globalThis.sym = Symbol.for('reg' + 1); 0")
	held := capi.JS_NewAtom(ctx, "held-by-the-host")
	capi.JS_RunGC(rt)
	freed0 := rtj.atoms_freed
	live0 := js.atoms_live(rtj)
	eval(ctx, "(function () { for (var i = 0; i < 20000; i++) { var o = {}; o['tmp' + i] = i; if (!(('tmp' + i) in o)) throw 1; } })(); 0")
	capi.JS_RunGC(rt)
	check(rtj.atoms_freed - freed0 >= 19000 && js.atoms_live(rtj) < live0 + 1000, fmt.tprintf("dropped keys are freed (%d freed, %d live, %d before)", rtj.atoms_freed - freed0, js.atoms_live(rtj), live0))
	slots := len(rtj.atoms)
	check(is_int(eval(ctx, "(function () { var o = {}, s = 0; for (var i = 0; i < 5000; i++) o['new' + i] = i; for (var i = 0; i < 5000; i++) s += o['n' + 'ew' + i]; return s === 12497500 ? 1 : 0 })()"), 1), "keys in freed slots are the keys they spell")
	check(len(rtj.atoms) <= slots + 100, fmt.tprintf("new keys take the freed slots (%d slots, then %d)", slots, len(rtj.atoms)))
	capi.JS_RunGC(rt)
	check(is_int(eval(ctx, "kept['ke' + 'pt7']"), 7), "a key a live object holds survives the collections")
	check(text(ctx, eval(ctx, "String(Symbol.for('re' + 'g1') === sym)")) == "true", "a registered symbol's key survives")
	check(text(ctx, eval(ctx, "(function () { var o = {}; o['a' + 1] = 1; o['b' + 2] = 2; var r = ''; for (var k in o) { delete o.b2; r += k; } return r })()")) == "a1", "for-in over keys deleted in the loop")
	hs := capi.JS_AtomToString(ctx, held)
	check(text(ctx, hs) == "held-by-the-host", "an atom the host holds survives the collections")
	capi.JS_FreeValue(ctx, hs)
	capi.JS_FreeAtom(ctx, held)
	// a getter that deletes the next key while the host walks the keys (JS_GetOwnPropertyNames owns them until freed)
	gv := eval(ctx, "globalThis.walked = { get ['x' + 1]() { delete walked['y' + 2]; for (var i = 0; i < 3000; i++) ({})['z' + i] = 0; return 1 }, ['y' + 2]: 2 }")
	wtab: [^]capi.Property_Enum
	wn: u32
	check(capi.JS_GetOwnPropertyNames(ctx, &wtab, &wn, gv, capi.GPN_STRING_MASK) == 0 && wn == 2, "the keys of walked")
	capi.JS_FreeValue(ctx, capi.JS_GetProperty(ctx, gv, wtab[0].atom))
	capi.JS_RunGC(rt)
	ws := capi.JS_AtomToString(ctx, wtab[1].atom)
	check(text(ctx, ws) == "y2", "a key the host holds is not freed when its property goes")
	capi.JS_FreeValue(ctx, ws)
	capi.JS_FreePropertyEnum(ctx, wtab, wn)
	capi.JS_FreeValue(ctx, gv)
	// Map and Set: a loop of delete then set keeps the order and the values (the index is not rebuilt at each insert)
	check(text(ctx, eval(ctx, "(function () { var m = new Map(); for (var i = 0; i < 1000; i++) m.set(i, i); for (var i = 0; i < 100000; i++) { m.delete(i); m.set(i + 1000, i); } return m.size + ',' + m.get(100999) + ',' + m.keys().next().value })()")) == "1000,99999,100000", "Map: delete then set")
	check(text(ctx, eval(ctx, "(function () { var s = new Set(); for (var i = 0; i < 100; i++) s.add(i); var it = s.values(); it.next(); for (var i = 0; i < 5000; i++) { s.delete(i); s.add(i + 100); } return s.size + ',' + it.next().value })()")) == "100,5000", "Set: delete then add under an iterator")
	// holey arrays: a write past the elements or a delete inside them keeps the elements (holes in between); a hole is
	// no own property, a read goes on to the prototypes; a write far past them makes a dictionary
	// (a prototype of their own: an index key on Array.prototype would turn the array fast paths off for the rest of the run)
	check(text(ctx, eval(ctx, "(function () { var p = Object.create(Array.prototype); var a = []; a[3] = 'd'; a[0] = 'a'; var r = [a.length, 1 in a, a.hasOwnProperty(3), Object.keys(a).join(':'), JSON.stringify(a)]; Object.setPrototypeOf(a, p); p[1] = 'p'; r.push(a[1]); var s = ''; for (var k in a) s += k; r.push(s); delete p[1]; r.push(String(a[1])); delete a[0]; r.push(Object.keys(a).join(':')); a.length = 2; r.push(a.length, Object.keys(a).length); return r.join(',') })()")) == "4,false,true,0:3,[\"a\",null,null,\"d\"],p,031,undefined,3,2,0", "holey array: keys, in, JSON, prototype, for-in, delete, length")
	check(text(ctx, eval(ctx, "(function () { var log = ''; var p = Object.create(Array.prototype); Object.defineProperty(p, 1, {set: function (v) { log += 'set' + v }}); var a = [1, 2, 3]; delete a[1]; Object.setPrototypeOf(a, p); a[1] = 5; return log + ',' + a.hasOwnProperty(1) + ',' + a.length })()")) == "set5,false,3", "holey array: a write into a hole meets a setter of the prototype")
	check(text(ctx, eval(ctx, "(function () { 'use strict'; var a = [1, 2, 3]; delete a[1]; Object.preventExtensions(a); try { a[1] = 2; return 'no throw' } catch (e) { return (e instanceof TypeError) + ',' + (1 in a) + ',' + a[2] } })()")) == "true,false,3", "holey array: no new element in a hole of a non-extensible array")
	check(text(ctx, eval(ctx, "(function () { var a = [1, 2, 3]; delete a[1]; Object.freeze(a); a[0] = 9; return Object.isFrozen(a) + ',' + Object.keys(a) + ',' + a[0] })()")) == "true,0,2,1", "holey array: freeze")
	check(text(ctx, eval(ctx, "(function () { var a = [1, 2, 3]; delete a[1]; var b = [3, 2, 1]; delete b[1]; b.sort(); return [[...a].length, 1 in [...a], 1 in a.map(x => x * 2), a.indexOf(undefined), a.includes(undefined), Object.keys(b).join(':'), b.length, Math.max.apply(null, a), a.join('-')].join(',') })()")) == "3,true,false,-1,true,0:1,3,NaN,1--3", "holey array: spread, map, indexOf, includes, sort, apply, join")
	check(text(ctx, eval(ctx, "(function () { var a = []; for (var i = 99; i >= 0; i--) a[i] = i; var s = 0; for (i = 0; i < 100; i++) s += a[i]; return s + ',' + a.length + ',' + Object.keys(a).length + ',' + Object.getOwnPropertyNames(a).length })()")) == "4950,100,100,101", "holey array: filled from its end")
	hv := eval(ctx, "globalThis.holes = []; for (var i = 9; i >= 0; i--) holes[i] = i; holes")
	ho := js.as_obj(capi.dec(hv))
	check(!ho.fast_array && len(ho.shape.props) == 1 && ho.data.(js.Array_Data).count == 10, "an array filled from its end keeps its elements (holey, not a dictionary)")
	capi.JS_FreeValue(ctx, hv)
	check(is_int(eval(ctx, "holes.length = 0; holes.push(7); holes[0]"), 7) && ho.fast_array, "a holey array emptied is fast again")
	sv := eval(ctx, "globalThis.sparse = []; sparse[100000] = 1; sparse")
	so := js.as_obj(capi.dec(sv))
	check(!so.fast_array && so.data.(js.Array_Data).count == 0 && len(so.shape.props) == 2, "a write far past the elements makes a dictionary")
	capi.JS_FreeValue(ctx, sv)
	check(text(ctx, eval(ctx, "sparse.length + ',' + sparse[100000] + ',' + Object.keys(sparse)")) == "100001,1,100000", "the dictionary array reads the same")
	// shapes: the shapes of a chain of transitions share one block of keys and its table; a shape that is the start of a
	// block does not see the keys after it; a second branch copies its start; blocks go with their last shape
	cv := eval(ctx, "globalThis.chain = {}; for (var i = 0; i < 40; i++) chain['k' + i] = i; chain")
	csh := js.as_obj(capi.dec(cv)).shape
	check(!csh.is_dict && len(csh.props) == 40 && csh.block != nil && csh.block.refs >= 10 && raw_data(csh.props) == js.props_block_entries(csh.block), "the shapes of a chain share their keys")
	capi.JS_FreeValue(ctx, cv)
	check(text(ctx, eval(ctx, "(function () { var c = {}; for (var i = 0; i < 20; i++) c['p' + i] = i; var e = {}; for (var i = 0; i < 12; i++) e['p' + i] = i; var r = [('p12' in e), ('p19' in e), e.p11, e.p0, Object.keys(e).length]; e.q = 'q'; r.push('p12' in e, e.q, ('q' in c), c.p19, Object.keys(c).length, Object.keys(e).join('').length); return r.join(',') })()")) == "false,false,11,0,12,false,q,false,19,20,27", "a shape that starts a shared block, then a branch of it")
	check(text(ctx, eval(ctx, "(function () { var a = {x: 1}; a.y = 2; a.z = 3; var b = {x: 1}; b.y = 2; b.w = 4; return Object.keys(a) + '|' + Object.keys(b) + '|' + ('z' in b) + ('w' in a) })()")) == "x,y,z|x,y,w|falsefalse", "two branches of one shape")
	eval(ctx, "(function () { for (var j = 0; j < 300; j++) { var o = {}; for (var i = 0; i < 30; i++) o['g' + (j % 7) + '_' + i] = i; } })(); 0")
	capi.JS_RunGC(rt)
	check(text(ctx, eval(ctx, "(function () { var s = 0, o; for (var j = 0; j < 7; j++) { o = {}; for (var i = 0; i < 30; i++) o['g' + j + '_' + i] = i; for (var i = 0; i < 30; i++) s += o['g' + j + '_' + i]; } var d = {}; for (var i = 0; i < 60; i++) d['m' + i] = i; delete d.m3; var t = {a: 1, b: 2, c: 3}; delete t.b; return s + ',' + Object.keys(d).length + ',' + d.m59 + ',' + Object.keys(t) + ',' + chain.k39 + ',' + ('k40' in chain) })()")) == "3045,59,59,a,c,39,false", "shapes after a collection freed blocks; dictionaries")
	// strings: a long slice shares its string's units and reads the same; equality and order by width
	check(text(ctx, eval(ctx, "(function () { var b = 'x'.repeat(100) + 'abc' + 'y'.repeat(100); var p = b.slice(50, 160); return p.length + ',' + p.indexOf('abc') + ',' + (p === 'x'.repeat(50) + 'abc' + 'y'.repeat(57)) })()")) == "110,50,true", "a long slice")
	check(text(ctx, eval(ctx, "String(['b\\u0100', 'a\\u0100', 'a', 'ab'.repeat(20) + 'c', 'ab'.repeat(20) + 'b'].sort())")) == strings.concatenate({"a,ab", strings.repeat("ab", 19, context.temp_allocator), "b,ab", strings.repeat("ab", 19, context.temp_allocator), "c,aĀ,bĀ"}, context.temp_allocator), "compare of strings by width")
	check(is_int(eval(ctx, "('abc' + 'x'.repeat(40) + 'abc').lastIndexOf('abc')"), 43), "lastIndexOf")
	check(is_int(eval(ctx, "'a\\u0100bca\\u0100b'.lastIndexOf('a\\u0100', 3)"), 0), "lastIndexOf, 16-bit, from a position")
	check(text(ctx, eval(ctx, "JSON.stringify({a: 1, '\\u0101': undefined, b: 2})")) == "{\"a\":1,\"b\":2}", "JSON: a 16-bit key rolled back")
	check(text(ctx, eval(ctx, "var big = ''; for (var i = 0; i < 2000; i++) big += String.fromCharCode(65 + i % 26); var j = [big, big].join(''); j.length + ',' + (j + '!').length + ',' + j.charAt(3999)")) == "4000,4001,X", "a joined string's buffer, appended to")

	// the search of indexOf and replace, each width of string against each width of pattern (Ā makes a string 16-bit)
	check(is_int(eval(ctx, "'abcabd'.indexOf('abd')"), 3), "indexOf: the first unit matches earlier than the pattern")
	check(is_int(eval(ctx, "'aaab'.indexOf('ab', 1)"), 2), "indexOf from a position")
	check(is_int(eval(ctx, "'abc'.indexOf('c')"), 2), "indexOf of one unit")
	check(is_int(eval(ctx, "'abc'.indexOf('abcd')"), -1), "indexOf of a longer pattern")
	check(is_int(eval(ctx, "'a\\u0100b'.indexOf('b')"), 2), "indexOf: a 16-bit string, an 8-bit pattern")
	check(is_int(eval(ctx, "'a\\u0100b'.indexOf('\\u0100b')"), 1), "indexOf: 16-bit, 16-bit")
	check(is_int(eval(ctx, "'ab'.indexOf('\\u0161')"), -1), "indexOf: an 8-bit string, a pattern of a unit it cannot hold")
	check(is_int(eval(ctx, "'aab'.indexOf('a\\u0100'.slice(0, 1) + 'b')"), 1), "indexOf: a pattern 16-bit by its origin")
	check(text(ctx, eval(ctx, "'https://a.b/c?d'.replace('https:', '')")) == "//a.b/c?d", "replace at the start")
	check(text(ctx, eval(ctx, "'a?x=1'.replace('?x=1', '')")) == "a", "replace at the end")
	check(text(ctx, eval(ctx, "'abc'.replace('b', '-$&-')")) == "a-b-c", "replace: a pattern of substitution")
	check(text(ctx, eval(ctx, "'abc'.replace('z', 'y')")) == "abc", "replace: no match")
	check(text(ctx, eval(ctx, "'ab'.replace('ab', '')")) == "", "replace to the empty string")
	check(text(ctx, eval(ctx, "'ab'.replace('b', '')")) == "a", "replace to one unit")
	check(text(ctx, eval(ctx, "'a\\u0100'.replace('a', 'b')")) == "bĀ", "replace in a 16-bit string")
	check(text(ctx, eval(ctx, "'ab'.replace('a', '\\u0100')")) == "Āb", "replace by a 16-bit string")
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
	// the finalizers' pass goes through the objects of such classes, not through the heap: what is listed is what lives
	listed := len((cast(^js.Runtime)rt).host_finals)
	eval(ctx, "globalThis.two = [mk(1), mk(2)]; globalThis.plain = []; for (var i = 0; i < 1000; i++) plain.push({}); mk(3); 0")
	capi.JS_RunGC(rt)
	check(len((cast(^js.Runtime)rt).host_finals) == listed + 2, fmt.tprintf("two more points listed (%d, then %d)", listed, len((cast(^js.Runtime)rt).host_finals)))
	eval(ctx, "two = plain = null; 0")
	capi.JS_RunGC(rt)
	check(len((cast(^js.Runtime)rt).host_finals) == listed, "and off the list when collected")

	// the epilogue: once a collection, after its finalizers (the glue unpins the nodes they released in one call)
	capi.JS_SetGCEpilogue(rt, count_epilogue, nil)
	base = finalized
	eval(ctx, "mk(3); 0")
	capi.JS_RunGC(rt)
	check(epilogues == 1 && finalized > base && finalized_at_epilogue == finalized, "the epilogue runs once, after the finalizers")
	capi.JS_SetGCEpilogue(rt, nil, nil)
	capi.JS_RunGC(rt)
	check(epilogues == 1, "no epilogue once unset")

	// a string's bytes read in place: ASCII only (its UTF-8), a rope flattened first, nothing for anything else
	ascii := capi.JS_DupValue(ctx, eval(ctx, "'li'"))
	rope := capi.JS_DupValue(ctx, eval(ctx, "var s = 'item '; for (var i = 0; i < 3; i++) s += i; s"))
	vn, rn: uint
	vp := capi.JS_ToStringView(ctx, &vn, ascii)
	check(vp != nil && string(vp[:vn]) == "li" && capi.JS_ToStringView(ctx, &vn, ascii) == vp, "an ASCII string read in place")
	rp := capi.JS_ToStringView(ctx, &rn, rope)
	check(rp != nil && string(rp[:rn]) == "item 012", "a concatenation read in place")
	for src in ([]string{"'caf\\u00e9'", "'\\ud83d\\ude00'", "12", "({})"}) {
		check(capi.JS_ToStringView(ctx, &vn, eval(ctx, src)) == nil, fmt.tprintf("no view of %s", src))
	}
	capi.JS_FreeValue(ctx, ascii)
	capi.JS_FreeValue(ctx, rope)

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

	// opaque data in the object's own block (JS_NewObjectProtoClassPayload, the glue's wrappers): zeroed, one block per
	// object, what it holds traced through gc_mark, freed with the object (the finalizer frees nothing of its own)
	capi.JS_NewClassID(rt, &cls_pod)
	pdef := capi.Class_Def{class_name = "Pod", finalizer = pod_finalizer, gc_mark = pod_gc_mark}
	check(capi.JS_NewClass(rt, cls_pod, &pdef) == 0, "JS_NewClass (payload)")
	q1 := capi.JS_NewObjectProtoClassPayload(ctx, capi.NULL, cls_pod, size_of(Point))
	q2 := capi.JS_NewObjectProtoClassPayload(ctx, capi.NULL, cls_pod, size_of(Point))
	d1, d2 := cast(^Point)capi.JS_GetOpaque(q1, cls_pod), cast(^Point)capi.JS_GetOpaque(q2, cls_pod)
	check(d1 != nil && d2 != nil && d1 != d2 && d1.x == 0 && d1.held == 0 && d2.held == 0, "payloads: one each, zeroed")
	check(uintptr(d1) % 8 == 0 && capi.JS_GetOpaque(q1, cls_point) == nil, "a payload is 8-aligned, and its class's only")
	half := eval(ctx, "-0.5")   // (a float: its high word is no tag, whatever its value)
	check(capi.JS_GetOpaque(half, cls_pod) == nil && capi.JS_GetClassID(half) == 0 && capi.JS_GetClassID(capi.mkval(capi.TAG_INT, 5)) == 0, "no object, no opaque data, no class")
	check(capi.JS_DupValue(ctx, half) == half && capi.JS_GetClassID(q1) == cls_pod, "a float is no reference; an object's class")
	// JS_GetAnyOpaque: JS_GetClassID's answer and the opaque data in one call
	any_id: capi.Class_ID
	check(capi.JS_GetAnyOpaque(q1, &any_id) == d1 && any_id == cls_pod, "JS_GetAnyOpaque: a payload and its class")
	plain := eval(ctx, "({})")
	any_id = 1
	check(capi.JS_GetAnyOpaque(plain, &any_id) == nil && any_id == capi.JS_GetClassID(plain), "JS_GetAnyOpaque: a built-in object's class, no data")
	any_id = 1
	check(capi.JS_GetAnyOpaque(half, &any_id) == nil && any_id == 0, "JS_GetAnyOpaque: no object, no class")
	capi.JS_FreeValue(ctx, plain)
	// gc_mark is not called for a payload object until it is marked (JS_SetOpaqueMarked); what its data counts is then a root
	d1.x, d2.x = 1, 2
	capi.JS_RunGC(rt)
	check(pod_marks == 0, fmt.tprintf("payload objects unmarked when made: gc_mark not called (%d)", pod_marks))
	d1.held, d2.held = capi.JS_DupValue(ctx, q2), capi.JS_DupValue(ctx, q1)   // a cycle through the payloads
	capi.JS_FreeValue(ctx, q1)
	capi.JS_FreeValue(ctx, q2)
	capi.JS_RunGC(rt)
	check(pods_finalized == 0 && pod_marks == 0 && d1.x == 1 && d2.x == 2, "unmarked: the values the payloads count are roots, the cycle kept")
	capi.JS_SetOpaqueMarked(ctx, q1, true)
	capi.JS_SetOpaqueMarked(ctx, q1, false)
	capi.JS_RunGC(rt)
	check(pods_finalized == 0 && pod_marks == 0, "marked, then unmarked: not asked")
	capi.JS_SetOpaqueMarked(ctx, q1, true)
	capi.JS_SetOpaqueMarked(ctx, q1, true)   // (twice: listed once)
	capi.JS_SetOpaqueMarked(ctx, q2, true)
	capi.JS_SetOpaqueMarked(ctx, half, true)   // (no object: nothing)
	capi.JS_RunGC(rt)
	check(pods_finalized == 2 && pod_marks == 2, fmt.tprintf("marked: a cycle through payloads is collected (%d of 2, gc_mark %d times)", pods_finalized, pod_marks))
	// made and dropped by the thousand: the payloads go back with their objects (were they kept, the heap would grow by
	// at least their bytes)
	usage: capi.Memory_Usage
	capi.JS_ComputeMemoryUsage(rt, &usage)
	before := usage.malloc_size
	for _ in 0 ..< PODS_SOAK {capi.JS_FreeValue(ctx, capi.JS_NewObjectProtoClassPayload(ctx, capi.NULL, cls_pod, size_of(Point)))}
	capi.JS_RunGC(rt)
	capi.JS_ComputeMemoryUsage(rt, &usage)
	check(pods_finalized == 2 + PODS_SOAK && usage.malloc_size < before + PODS_SOAK * size_of(Point), fmt.tprintf("payloads freed with their objects (%d finalized, heap %d -> %d bytes)", pods_finalized, before, usage.malloc_size))

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
	shared_ops := capi.Host_Shared{read = shared_read, write = shared_write}
	sab := capi.JS_NewArrayBufferShared(ctx, len(shared_bytes), &shared_ops, 0, false, -1)
	capi.JS_SetPropertyStr(ctx, global, "sab", sab)
	check(is_int(eval(ctx, "globalThis.sv = new Int32Array(sab); sv[0] = 2; sv[0]"), 2), "a shared host buffer written and read")
	shared_bytes[0] = 3   // (another agent, between two calls: a message says so)
	check(is_int(eval(ctx, "sv[0]"), 3), "the next call reads what another agent wrote")
	check(shared_bytes[0] == 3 && eval(ctx, "sv[1] = 7; 0") == capi.mkval(capi.TAG_INT, 0) && shared_bytes[4] == 7, "a write reaches the host at once")

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

	// --- a function broken in the stream: the script loads and runs, a call of that function throws, each time; no stream can hold
	// the instruction a function that has not run starts with ---
	PUSH_I32 :: 1
	LAZY_BODY :: u8(js.Opcode.lazy_body)
	marked := [?]u8{PUSH_I32, 0xb1, 0xcb, 0x74, 0}   // push_i32 7654321
	code = "globalThis.broken = function () { return 7654321; }; globalThis.sound = function () { return 5; };"
	fnv = capi.JS_Eval(ctx, raw_data(code), uint(len(code)), "broken.js", capi.EVAL_FLAG_COMPILE_ONLY)
	img = capi.JS_WriteObject(ctx, &size, fnv, capi.WRITE_OBJ_BYTECODE)
	at := -1
	for i in 0 ..< int(size) - len(marked) {
		if mem.compare(img[i:i + len(marked)], marked[:]) == 0 {at = i}
	}
	check(at >= 0, "the function's code is in the stream")
	img[at] = LAZY_BODY
	fn2 = capi.JS_ReadObject(ctx, img, size, capi.READ_OBJ_BYTECODE)
	check(capi.tag_of(fn2) != capi.TAG_EXCEPTION, "a stream with a broken function loads")
	capi.JS_FreeValue(ctx, capi.JS_EvalFunction(ctx, fn2))
	check(is_int(eval(ctx, "sound()"), 5), "the other functions run")
	caught := "(function () { try { broken() } catch (e) { return e instanceof SyntaxError ? 1 : 2 } return 0 })()"
	check(is_int(eval(ctx, caught), 1), "the broken function throws at its call")
	check(is_int(eval(ctx, caught), 1), "... and at its next")
	capi.js_free(ctx, img)
	capi.JS_FreeValue(ctx, fnv)

	// --- a block over the heap limit: a RangeError the script catches, not a trap ---
	capi.JS_RunGC(rt)
	lim: capi.Memory_Usage
	capi.JS_ComputeMemoryUsage(rt, &lim)
	capi.JS_SetMemoryLimit(rt, uint(lim.malloc_size + (8 << 20)))
	oom_check := "(function (f) { try { f(); return 0 } catch (e) { return e instanceof RangeError ? 1 : 2 } })"
	check(is_int(eval(ctx, strings.concatenate({oom_check, "(() => 'x'.repeat(2 ** 28))"}, context.temp_allocator)), 1), "repeat past the heap limit")
	check(is_int(eval(ctx, strings.concatenate({oom_check, "(() => 'ab'.padEnd(2 ** 28, 'c'))"}, context.temp_allocator)), 1), "padEnd past the heap limit")
	check(is_int(eval(ctx, strings.concatenate({oom_check, "(() => Array.prototype.toReversed.call({length: 4e9}))"}, context.temp_allocator)), 1), "toReversed of a length past any block")
	check(is_int(eval(ctx, "'x'.repeat(1000).length"), 1000), "and the engine goes on")
	capi.JS_SetMemoryLimit(rt, 0)

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
