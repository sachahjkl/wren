// web_clone.odin: structured serialization as the rest of the runtime keeps it (history.state, MessagePort,
// window.postMessage, BroadcastChannel, IndexedDB values, performance marks): web_clone_serialize / _free /
// _deserialize, and the transfer list of StructuredSerializeOptions. Ported from native/js/runtime/web_clone.c; same
// symbols and behaviour.
//
// A tag byte in front says which serializer wrote the bytes (a state kept in the session history outlives the build
// that wrote it): 2 for HTML's structured serialization (clone.odin, written straight after the tag in one block), 1
// for the engine's own object serializer, which older builds used when clone.c was not linked (read only now).
package odin_glue

import "../odin/wj"

@(private = "file") CLONE_ENGINE :: u8(1)
@(private = "file") CLONE_SHARED :: u8(2)

// The serialized bytes (free with web_clone_free), or nil with a DataCloneError pending.
@(export, link_name = "web_clone_serialize")
web_clone_serialize :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, length: ^uint) -> [^]u8 {
	tag := [1]u8{CLONE_SHARED}
	return clone_serialize_no_ports(ctx, v, wj.UNDEFINED, tag[:], length)
}

@(export, link_name = "web_clone_free")
web_clone_free :: proc "c" (ctx: ^wj.Context, p: rawptr) { wj.libc_free(p) }

@(export, link_name = "web_clone_deserialize")
web_clone_deserialize :: proc "c" (ctx: ^wj.Context, p: [^]u8, n: uint) -> wj.JSValue {
	if n >= 1 && p[0] == CLONE_SHARED { return wj_clone_deserialize(ctx, p[1:], n - 1) }
	if n >= 1 && p[0] == CLONE_ENGINE {
		v := wj.JS_ReadObject(ctx, p[1:], n - 1, wj.READ_OBJ_REFERENCE)
		if !wj.is_exception(v) { return v }
		wj.drop_exception(ctx)
	}
	return wj.wj_throw_dom(ctx, "DataCloneError", "The data could not be deserialized.")
}

@(private = "file")
Transfer_List :: struct { list: wj.JSValue, n: u32 }

@(private = "file")
transfer_item :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	t := (^Transfer_List)(opaque)
	if !wj.wj_is_array_buffer(item) {
		wj.wj_throw_dom(ctx, "DataCloneError", "Value at index in the transfer list is not a transferable object.")
		return false
	}
	for i in 0 ..< t.n {
		x := wj.JS_GetPropertyUint32(ctx, t.list, i)
		same := wj.same_ptr(x, item)
		wj.JS_FreeValue(ctx, x)
		if same { wj.wj_throw_dom(ctx, "DataCloneError", "ArrayBuffer at index is a duplicate of an earlier ArrayBuffer."); return false }
	}
	wj.array_set(ctx, t.list, t.n, wj.JS_DupValue(ctx, item))
	t.n += 1
	return true
}

// The transfer list of StructuredSerializeOptions ({transfer}) or of a sequence: an array (counted).
@(export, link_name = "web_transfer_list")
web_transfer_list :: proc "c" (ctx: ^wj.Context, opt_or_seq: wj.JSValue, is_options: bool) -> wj.JSValue {
	t := Transfer_List{wj.JS_NewArray(ctx), 0}
	seq := wj.UNDEFINED
	if is_options {
		if !wj.web_dict_check(ctx, opt_or_seq, "structuredClone") || !wj.web_dict_get(ctx, opt_or_seq, "transfer", &seq) {
			wj.JS_FreeValue(ctx, t.list)
			return wj.EXCEPTION
		}
	} else {
		seq = wj.JS_DupValue(ctx, opt_or_seq)
	}
	defer wj.JS_FreeValue(ctx, seq)
	if !wj.is_undefined(seq) && !wj.web_for_of(ctx, seq, transfer_item, &t) { wj.JS_FreeValue(ctx, t.list); return wj.EXCEPTION }
	return t.list
}

// The ArrayBuffers of a transfer list detached (once the message they went with is serialized).
@(export, link_name = "web_transfer_detach")
web_transfer_detach :: proc "c" (ctx: ^wj.Context, list: wj.JSValue) {
	n := wj.length_of(ctx, list)
	for i in 0 ..< n {
		ab := wj.JS_GetPropertyUint32(ctx, list, u32(i))
		wj.JS_DetachArrayBuffer(ctx, ab)
		wj.JS_FreeValue(ctx, ab)
	}
}
