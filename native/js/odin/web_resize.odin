// web_resize.odin: ResizeObserver, ResizeObserverEntry and ResizeObserverSize (Resize Observer §3), the engine's side.
// Ported from native/js/runtime/web_resize.c with the same behaviour and the same wjr_* / wj_cb_resize symbols. The
// observations are the browser's (src/page/js_resize_observer.odin); this file keeps what the script holds (the observer
// with its callback) and makes the entry and size objects handed to the callback at each rendering update. See
// docs/js/odin-glue.md.
package odin_glue

import "../odin/wj"

Box :: enum i32 { Content = 0, Border = 1, Device = 2 }

RO_Impl :: struct {
	host:     u64,
	callback: wj.JSValue,   // counted
	slot:     i32,
	pin:      u32,          // web_pin token: the observer lives while it observes a target
}

// observers by slot (the notification's `user`), not counted
@(private = "file") ro_slots: [^]wj.JSValue
@(private = "file") ro_slot_cap: i32

@(private = "file")
ro_free :: proc "c" (p: rawptr) {
	m := (^RO_Impl)(p)
	if m.slot > 0 && m.slot < ro_slot_cap { ro_slots[m.slot] = wj.UNDEFINED }
	if m.host != 0 { wj.wr_Object_release(m.host) }
	wj.JS_FreeValueRT(wj.the_runtime(wj.wj_the_realm.ctx), m.callback)
	wj.libc_free(m)
}

@(private = "file")
ro_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^RO_Impl)(p).callback, mark_func) }

@(private = "file")
ro_of :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^RO_Impl {
	o := wj.wj_this(ctx, this_val, iface_resize_observer())
	if o == nil { return nil }
	if o.impl == nil || o.impl_free != ro_free { wj.wj_throw_type(ctx, "Illegal invocation"); return nil }
	return (^RO_Impl)(o.impl)
}

// An observer that observes a target is kept alive by the page's layout, as one referenced from the script is.
@(private = "file")
ro_sync_pin :: proc "c" (ctx: ^wj.Context, m: ^RO_Impl, self: wj.JSValue) {
	n := wj.wr_ResizeObserver_observed(m.host)
	if n > 0 && m.pin == 0 { m.pin = wj.web_pin(ctx, self) }
	else if n == 0 && m.pin != 0 { wj.web_unpin(ctx, m.pin); m.pin = 0 }
}

// interface indices resolved once, by name (robust against renumbering).
@(private = "file") iface_ro := i32(-2)
@(private = "file") iface_roe := i32(-2)
@(private = "file") iface_ros := i32(-2)
@(private = "file") iface_resize_observer :: proc "c" () -> i32 { if iface_ro == -2 { iface_ro = wj.iface("ResizeObserver") }; return iface_ro }
@(private = "file") iface_entry :: proc "c" () -> i32 { if iface_roe == -2 { iface_roe = wj.iface("ResizeObserverEntry") }; return iface_roe }
@(private = "file") iface_size :: proc "c" () -> i32 { if iface_ros == -2 { iface_ros = wj.iface("ResizeObserverSize") }; return iface_ros }

@(export, link_name = "wjr_ResizeObserver_constructor")
wjr_ResizeObserver_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Failed to construct 'ResizeObserver': Please use the 'new' operator, this DOM object constructor cannot be called as a function.") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "ResizeObserver", 1, argc) }
	if !wj.JS_IsFunction(ctx, argv[0]) { return wj.wj_throw_type(ctx, "Failed to construct 'ResizeObserver': The callback provided as parameter 1 is not a function.") }
	slot := i32(1)
	for slot < ro_slot_cap && !wj.is_undefined(ro_slots[slot]) { slot += 1 }
	if slot >= ro_slot_cap {
		cap := ro_slot_cap != 0 ? ro_slot_cap * 2 : 16
		s := ([^]wj.JSValue)(wj.libc_realloc(ro_slots, uint(cap) * size_of(wj.JSValue)))
		if s == nil { return wj.JS_ThrowOutOfMemory(ctx) }
		for i := ro_slot_cap; i < cap; i += 1 { s[i] = wj.UNDEFINED }
		ro_slots = s
		ro_slot_cap = cap
	}
	m := (^RO_Impl)(wj.libc_calloc(1, size_of(RO_Impl)))
	if m == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	m.host = wj.wr_ResizeObserver_create(wj.table_index(rawptr(wj_cb_resize)), slot)
	if m.host == 0 { wj.libc_free(m); return wj.wj_throw_type(ctx, "Failed to construct 'ResizeObserver': there is no document to observe") }
	m.callback = wj.JS_DupValue(ctx, argv[0])
	m.slot = slot
	obj := wj.wj_new_object_for(ctx, iface_resize_observer(), new_target, m, ro_free)
	if wj.is_exception(obj) { return obj }
	wj.obj_of(obj).impl_mark = ro_mark
	ro_slots[slot] = obj
	return obj
}

@(export, link_name = "wjr_ResizeObserver_observe")
wjr_ResizeObserver_observe :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	m := ro_of(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "ResizeObserver.observe", 1, argc) }
	target: u64
	if !wj.wj_to_handle(ctx, argv[0], iface_element(), false, &target, "Failed to execute 'observe' on 'ResizeObserver': parameter 1 is not of type 'Element'.") { return wj.EXCEPTION }
	options: wjd_ResizeObserverOptions
	if !wjd_ResizeObserverOptions_from(ctx, wj.arg(argc, argv, 1), &options) { return wj.EXCEPTION }
	box := Box.Content
	if options.box.len == 10 && wj.str_eq(options.box.ptr, "border-box") { box = .Border }
	else if options.box.len == 24 { box = .Device }   // the enum was checked: device-pixel-content-box
	wjd_ResizeObserverOptions_free(ctx, &options)
	st := wj.wr_ResizeObserver_observe(m.host, target, i32(box))
	if st < 0 { return wj.wj_throw_status(ctx, st, "ResizeObserver.observe") }
	ro_sync_pin(ctx, m, this_val)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_ResizeObserver_unobserve")
wjr_ResizeObserver_unobserve :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	m := ro_of(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "ResizeObserver.unobserve", 1, argc) }
	target: u64
	if !wj.wj_to_handle(ctx, argv[0], iface_element(), false, &target, "Failed to execute 'unobserve' on 'ResizeObserver': parameter 1 is not of type 'Element'.") { return wj.EXCEPTION }
	wj.wr_ResizeObserver_unobserve(m.host, target)
	ro_sync_pin(ctx, m, this_val)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_ResizeObserver_disconnect")
wjr_ResizeObserver_disconnect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	m := ro_of(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	wj.wr_ResizeObserver_disconnect(m.host)
	ro_sync_pin(ctx, m, this_val)
	return wj.UNDEFINED
}

// ---- entries and sizes ----

RE :: enum i32 { Target = 0, Rect = 1, Border = 2, Content = 3, Device = 4 }
RE_COUNT :: 5
RE_BYTES :: 8 + 8 * 8   // target u64, eight f64: see api/js_observers.widl

// a FrozenArray<ResizeObserverSize> of one size (Object.freeze, as the other frozen arrays of the realm)
@(private = "file")
size_array :: proc "c" (ctx: ^wj.Context, inline_size: f64, block_size: f64) -> wj.JSValue {
	d: ^wj.Dom_Impl
	size := wj.dom_new(ctx, iface_size(), wj.DOM_RECT, wj.UNDEFINED, 0, &d)
	if wj.is_exception(size) { return size }
	d.rect[0] = inline_size
	d.rect[1] = block_size
	arr := wj.JS_NewArray(ctx)
	if wj.is_exception(arr) { wj.JS_FreeValue(ctx, size); return arr }
	wj.array_set(ctx, arr, 0, size)
	if !wj.web_freeze(ctx, arr) { wj.JS_FreeValue(ctx, arr); return wj.EXCEPTION }
	return arr
}

@(private = "file")
make_entry :: proc "c" (ctx: ^wj.Context, p: [^]u8) -> wj.JSValue {
	v: [8]f64
	for i in 0..<8 {
		bits := wj.read_u64(p[8 + 8 * i:])
		v[i] = transmute(f64)bits
	}
	d: ^wj.Dom_Impl
	e := wj.dom_new(ctx, iface_entry(), wj.DOM_VALUES, wj.UNDEFINED, 0, &d)
	if wj.is_exception(e) { return e }
	d.values = ([^]wj.JSValue)(wj.libc_calloc(RE_COUNT, size_of(wj.JSValue)))
	if d.values == nil { wj.JS_FreeValue(ctx, e); return wj.JS_ThrowOutOfMemory(ctx) }
	d.n_values = RE_COUNT
	for i in 0..<RE_COUNT { d.values[i] = wj.UNDEFINED }
	d.values[RE.Target] = wj.wj_wrap_node(ctx, wj.read_u64(p))
	// contentRect: the content box, at the padding's offset (left, top)
	d.values[RE.Rect] = dom_rect_new(ctx, v[6], v[7], v[2], v[3], true)
	d.values[RE.Border] = size_array(ctx, v[0], v[1])
	d.values[RE.Content] = size_array(ctx, v[2], v[3])
	d.values[RE.Device] = size_array(ctx, v[4], v[5])
	for i in 0..<RE_COUNT {
		if wj.is_exception(d.values[i]) { wj.JS_FreeValue(ctx, e); return wj.EXCEPTION }
	}
	return e
}

@(private = "file")
entry_field :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, i: i32) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, iface_entry())
	if d == nil { return wj.EXCEPTION }
	return i < i32(d.n_values) ? wj.JS_DupValue(ctx, d.values[i]) : wj.UNDEFINED
}

@(export, link_name = "wjr_ResizeObserverEntry_get_target")
wjr_ResizeObserverEntry_get_target :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(RE.Target)) }
@(export, link_name = "wjr_ResizeObserverEntry_get_contentRect")
wjr_ResizeObserverEntry_get_contentRect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(RE.Rect)) }
@(export, link_name = "wjr_ResizeObserverEntry_get_borderBoxSize")
wjr_ResizeObserverEntry_get_borderBoxSize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(RE.Border)) }
@(export, link_name = "wjr_ResizeObserverEntry_get_contentBoxSize")
wjr_ResizeObserverEntry_get_contentBoxSize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(RE.Content)) }
@(export, link_name = "wjr_ResizeObserverEntry_get_devicePixelContentBoxSize")
wjr_ResizeObserverEntry_get_devicePixelContentBoxSize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(RE.Device)) }

@(export, link_name = "wjr_ResizeObserverSize_get_inlineSize")
wjr_ResizeObserverSize_get_inlineSize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, iface_size())
	return d != nil ? wj.new_float64(ctx, d.rect[0]) : wj.EXCEPTION
}

@(export, link_name = "wjr_ResizeObserverSize_get_blockSize")
wjr_ResizeObserverSize_get_blockSize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, iface_size())
	return d != nil ? wj.new_float64(ctx, d.rect[1]) : wj.EXCEPTION
}

// The browser has entries for an observer (called inside a rendering update, after the layout): the script's callback
// gets them.
@(export, link_name = "wj_cb_resize")
wj_cb_resize :: proc "c" (user: i32) {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	if user <= 0 || user >= ro_slot_cap || wj.is_undefined(ro_slots[user]) { return }
	self := wj.JS_DupValue(ctx, ro_slots[user])
	m := (^RO_Impl)(wj.obj_of(self).impl)
	cb_host := m.host
	// WJ_FETCH_STRING: grow the scratch until takeEntries fits.
	n := wj.wr_ResizeObserver_takeEntries(cb_host, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap {
		if wj.wj_scratch_grow(u32(n)) { n = wj.wr_ResizeObserver_takeEntries(cb_host, wj.wj_scratch.data, wj.wj_scratch.cap) }
	}
	if n >= RE_BYTES {
		buf := ([^]u8)(wj.libc_malloc(uint(n)))
		entries := buf != nil ? wj.JS_NewArray(ctx) : wj.EXCEPTION
		if buf != nil {
			wj.memcpy(buf, wj.wj_scratch.data, uint(n))
			k := u32(0)
			off := i32(0)
			for off + RE_BYTES <= n && !wj.is_exception(entries) {
				e := make_entry(ctx, buf[off:])
				if wj.is_exception(e) { wj.JS_FreeValue(ctx, entries); entries = wj.EXCEPTION; break }
				wj.array_set(ctx, entries, k, e); k += 1
				off += RE_BYTES
			}
			wj.libc_free(buf)
		}
		if wj.is_exception(entries) {
			wj.wj_report_pending(ctx)
		} else {
			args := [2]wj.JSValue{ entries, self }
			r := wj.JS_Call(ctx, m.callback, self, 2, &args[0])
			if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
			wj.JS_FreeValue(ctx, entries)
		}
	}
	wj.JS_FreeValue(ctx, self)
}
