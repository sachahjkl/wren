// wj_iface.odin: the Odin counterpart of the interface-table part of native/js/engine/wj.h.
//
// This file defines the types and the surface that bindgen's Odin output (-emit:odin) is generated against: the
// interface table (`Interface`, `Member`), the exposure / flag / member-kind enums, and the realm hooks the table
// drives. It is the seam between the generated glue (above it) and the engine (below it).
//
// STATUS: stubs. Agent spk owns the real engine-agnostic Odin layer (the equivalent of wj.h: Ctx, Val, the wj_to_*
// conversions, wj_wrap_*, the realm). Until that lands, this file declares exactly what the generated code and the
// hand-written members expect, with every procedure a stub that panics, so:
//   * `bindgen -emit:odin` output type-checks against a real surface (not against nothing);
//   * spk implements this file (or replaces these stubs) without changing a line of the generated code.
// When spk's layer exists, delete the stub bodies here and back them with the engine, or re-point the generated
// `import` at spk's package. The TYPES below are the contract: changing them changes the generated code.
package wj

// ---- value and context (spk owns the real definitions) ----

// A JavaScript value in the engine. Opaque to the generated glue; spk defines its representation.
Val :: distinct u64
// A JavaScript context / realm handle. Opaque to the generated glue.
Ctx :: distinct rawptr

UNDEFINED :: Val(0)
NULL :: Val(1)
EXCEPTION :: Val(2)

// The native signature of a generated member glue function (an operation, a static method, a constructor) and of an
// attribute's getter / setter. These match the shapes the C side used (wj_native / wj_getter / wj_setter), so the
// generated Odin trampolines have one uniform type per slot.
Native :: #type proc "contextless" (ctx: ^Ctx, this_val: Val, argc: i32, argv: [^]Val) -> Val
Getter :: #type proc "contextless" (ctx: ^Ctx, this_val: Val) -> Val
Setter :: #type proc "contextless" (ctx: ^Ctx, this_val: Val, v: Val) -> Val

// ---- interface table (generated: see src/tools/bindgen/jsgen) ----

// How a member appears on the prototype or the interface object. The names mirror wj.h's WJ_M_*; a tagged member
// (below) could replace the kind + the three function slots, but keeping them parallel to the C table makes the
// first port a transliteration spk can trust.
Member_Kind :: enum u8 {
	Method = 1,         // operation on the prototype (or the instance when unforgeable)
	Attribute,          // accessor on the prototype (or the instance when unforgeable)
	Constant,           // on the interface object and the prototype
	Static_Method,      // on the interface object
	Static_Attribute,
}

// Per-member flags ([LegacyUnforgeable], [Replaceable], [SameObject], realm masks...). A bit_set rather than C's
// bit flags: the generated table writes member-flag sets directly.
Member_Flag :: enum u8 {
	Unforgeable,        // [LegacyUnforgeable]: own, non-configurable property of each instance
	Replaceable,        // [Replaceable]: setting it defines an own data property
	Same_Object,        // [SameObject]: the getter's first result is kept
	Lenient_This,       // [LegacyLenientThis]: a wrong `this` gives undefined, no exception
	Not_Enumerable,
	Secure,             // [SecureContext]
	Not_Window,         // absent from this realm although its interface is there
	Not_Dedicated,
	Setter_Unsupported, // writable in the IDL, setting it is not implemented: throws
	Not_Shared,
	Not_Service,
}
Member_Flags :: bit_set[Member_Flag; u16]

// What a realm's global exposes, and what an interface is exposed to ([Exposed]).
Expose :: enum u8 { Window, Worker, Shared_Worker, Service_Worker }
Exposures :: bit_set[Expose; u8]

// Per-interface flags (WJ_I_* in wj.h).
Interface_Flag :: enum u8 {
	Global,             // [Global]: the realm's global object implements it
	No_Interface_Object,// mixin-like: no constructor property on the global
	Namespace,          // a Web IDL namespace (console, CSS): a plain object
	Callback,           // callback interface with constants (NodeFilter)
	Unsupported,        // nothing of it is implemented
	Override_Builtins,  // [LegacyOverrideBuiltIns]
	Has_Unforgeable,    // has [LegacyUnforgeable] members
	Secure,             // [SecureContext]
	Array_Iterator,     // value iterator of an indexed collection
	Ctor_Unsupported,   // has a constructor the browser does not implement
	Indexed_Iterator,   // indexed getter + length, no iterable declaration (Web IDL §3.7.6)
	Unenumerable_Named, // [LegacyUnenumerableNamedProperties]
}
Interface_Flags :: bit_set[Interface_Flag; u16]

// How instances answer property lookups beyond their prototype (Web IDL "legacy platform objects").
Class_Kind :: enum u8 { Plain, Indexed, Named }

// Legacy platform-object hooks (WJ_CLASS_INDEXED / NAMED): spk's engine calls these; nil means none.
Index_Get    :: #type proc "contextless" (ctx: ^Ctx, obj: Val, index: u32, found: ^bool) -> Val
Length_Get   :: #type proc "contextless" (ctx: ^Ctx, obj: Val) -> u32
Named_Get    :: #type proc "contextless" (ctx: ^Ctx, obj: Val, name: string, found: ^bool) -> Val
Named_Set    :: #type proc "contextless" (ctx: ^Ctx, obj: Val, name: string, value: Val) -> i32
Named_Delete :: #type proc "contextless" (ctx: ^Ctx, obj: Val, name: string) -> i32
Named_Keys   :: #type proc "contextless" (ctx: ^Ctx, obj: Val, array: Val) -> i32

// One member of an interface. The generated member tables (bindgen jsgen, Odin form) are `[]Member` literals.
Member :: struct {
	name:   string,
	kind:   Member_Kind,
	flags:  Member_Flags,
	length: u16,           // Function.length of a method; the [SameObject] slot of an attribute
	fn:     Native,        // method / operation (nil otherwise)
	get:    Getter,        // attribute getter (nil otherwise)
	set:    Setter,        // attribute setter (nil: readonly / unsupported)
	value:  f64,           // constant
}

// One interface in the table, numbered in pre-order of the inheritance tree so that "is an X" is a range check. The
// generated `interfaces` table is `[]Interface`; `wj.interfaces` and `wj.interface_count` are what the engine reads.
Interface :: struct {
	name:         string,
	parent:       i16,             // index in `interfaces`, -1 for none
	exposed:      Exposures,
	flags:        Interface_Flags,
	class_kind:   Class_Kind,
	ctor_length:  u16,
	ctor:         Native,          // nil: "Illegal constructor"
	members:      []Member,
	subtree_end:  u16,             // interfaces [index, subtree_end) inherit from this one (pre-order)
	index_get:    Index_Get,
	length_get:   Length_Get,
	named_get:    Named_Get,
	named_set:    Named_Set,
	named_delete: Named_Delete,
	named_keys:   Named_Keys,
	legacy_alias: string,          // [LegacyWindowAlias]
	factory_name: string,          // [LegacyFactoryFunction]
	factory:      Native,
	factory_length: u16,
}

// The generated table assigns these (src/page/js_interfaces_generated... the Odin jsgen output). Declared here as the
// symbols the engine reads; the generated file provides their values via @(link_name) or by being compiled together.
interfaces: []Interface
interface_count: int
same_object_count: int

// ---- what the generated trampolines need from the engine (spk owns the bodies) ----

// `this` of an operation / attribute of interface `iface`: the platform object behind it, or nil with a TypeError
// pending ("Illegal invocation"). The handle (the browser's object) is read from it.
this_handle :: proc "contextless" (ctx: ^Ctx, this_val: Val, iface: int) -> (handle: u64, ok: bool) {
	_ = ctx; _ = this_val; _ = iface
	return 0, false   // stub: spk's wj_this
}

// An argument of interface type: the handle behind a platform object of `iface` (or a descendant); 0 accepted when
// `nullable`. false with a TypeError `message` pending otherwise.
to_handle :: proc "contextless" (ctx: ^Ctx, v: Val, iface: int, nullable: bool, message: string) -> (handle: u64, ok: bool) {
	_ = ctx; _ = v; _ = iface; _ = nullable; _ = message
	return 0, false
}

// Web IDL ECMAScript-binding conversions; each returns ok=false with an exception pending when it throws. These are
// the ones the generated glue calls (the C side's wj_to_* / wj_throw_* / string scratch). spk implements them.
Range_Mode :: enum u8 { None, Enforce_Range, Clamp }

to_int32  :: proc "contextless" (ctx: ^Ctx, v: Val, bits: int, mode: Range_Mode) -> (out: i32,  ok: bool) { _ = ctx; _ = v; _ = bits; _ = mode; return 0, false }
to_uint32 :: proc "contextless" (ctx: ^Ctx, v: Val, bits: int, mode: Range_Mode) -> (out: u32,  ok: bool) { _ = ctx; _ = v; _ = bits; _ = mode; return 0, false }
to_int64  :: proc "contextless" (ctx: ^Ctx, v: Val, mode: Range_Mode)            -> (out: i64,  ok: bool) { _ = ctx; _ = v; _ = mode; return 0, false }
to_uint64 :: proc "contextless" (ctx: ^Ctx, v: Val, mode: Range_Mode)            -> (out: u64,  ok: bool) { _ = ctx; _ = v; _ = mode; return 0, false }
to_double :: proc "contextless" (ctx: ^Ctx, v: Val, restricted: bool)            -> (out: f64,  ok: bool) { _ = ctx; _ = v; _ = restricted; return 0, false }
to_bool   :: proc "contextless" (ctx: ^Ctx, v: Val)                              -> bool                  { _ = ctx; _ = v; return false }

// A converted UTF-8 string view (owned: free with str_free). The flags mirror wj.h's WJ_STR_*.
Str_Flag :: enum u8 { Nullable, Null_Empty, Optional, Usv }
Str_Flags :: bit_set[Str_Flag; u8]
Str :: struct { text: string, owned: bool }

to_str   :: proc "contextless" (ctx: ^Ctx, v: Val, flags: Str_Flags, def: string) -> (s: Str, ok: bool) { _ = ctx; _ = v; _ = flags; _ = def; return {}, false }
str_free :: proc "contextless" (ctx: ^Ctx, s: ^Str) { _ = ctx; _ = s }

// Results back to JavaScript.
new_bool    :: proc "contextless" (ctx: ^Ctx, b: bool) -> Val { _ = ctx; _ = b; return UNDEFINED }
new_int32   :: proc "contextless" (ctx: ^Ctx, n: i32)  -> Val { _ = ctx; _ = n; return UNDEFINED }
new_uint32  :: proc "contextless" (ctx: ^Ctx, n: u32)  -> Val { _ = ctx; _ = n; return UNDEFINED }
new_int64   :: proc "contextless" (ctx: ^Ctx, n: i64)  -> Val { _ = ctx; _ = n; return UNDEFINED }
new_double  :: proc "contextless" (ctx: ^Ctx, n: f64)  -> Val { _ = ctx; _ = n; return UNDEFINED }
new_string  :: proc "contextless" (ctx: ^Ctx, s: string) -> Val { _ = ctx; _ = s; return UNDEFINED }

// Wrap a browser handle as a platform object of an interface (node / host object), and the [Owned] variant.
wrap_node  :: proc "contextless" (ctx: ^Ctx, node: u64)                      -> Val { _ = ctx; _ = node; return UNDEFINED }
wrap_host  :: proc "contextless" (ctx: ^Ctx, handle: u64, iface: int)        -> Val { _ = ctx; _ = handle; _ = iface; return UNDEFINED }
wrap_owned :: proc "contextless" (ctx: ^Ctx, handle: u64, iface: int)        -> Val { _ = ctx; _ = handle; _ = iface; return UNDEFINED }

// Throw the exception for a negative browser Error `status`, with the message it recorded; the argument-count and the
// unsupported-member throwers; the arg accessor. All return EXCEPTION / a value so the glue can `return` them.
throw_status      :: proc "contextless" (ctx: ^Ctx, status: i32, what: string)            -> Val { _ = ctx; _ = status; _ = what; return EXCEPTION }
throw_arity       :: proc "contextless" (ctx: ^Ctx, what: string, required, given: i32)   -> Val { _ = ctx; _ = what; _ = required; _ = given; return EXCEPTION }
throw_unsupported :: proc "contextless" (ctx: ^Ctx, iface, member: string)                -> Val { _ = ctx; _ = iface; _ = member; return EXCEPTION }
arg               :: proc "contextless" (argc: i32, argv: [^]Val, i: int)                 -> Val { return i < int(argc) ? argv[i] : UNDEFINED }

// A scratch buffer for string results of browser functions (the C side's wj_scratch + WJ_FETCH_STRING): the engine
// owns it, the generated glue fills it. spk exposes its (ptr, cap) and the grow / string-making helpers.
scratch_ptr :: proc "contextless" () -> [^]u8 { return nil }
scratch_cap :: proc "contextless" () -> u32 { return 0 }
scratch_grow :: proc "contextless" (need: u32) -> bool { _ = need; return false }
