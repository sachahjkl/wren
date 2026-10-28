// intersection.odin: IntersectionObserver and IntersectionObserverEntry (Intersection Observer §3), the engine's side.
// Ported from native/js/runtime/intersection.c with the same behaviour and symbols (wjr_* and wj_cb_intersection). The
// observations and the geometry are the browser's (src/page/js_intersection_observer.odin); this file keeps what the
// script holds (the observer with its callback, root, thresholds and margins) and makes the entries handed to the
// callback. See docs/js/odin-glue.md.
package odin_glue

import "../odin/wj"

IO_Impl :: struct {
	host:             u64,
	callback:         wj.JSValue,   // counted
	root:             wj.JSValue,   // Element, Document or null
	thresholds:       wj.JSValue,   // the frozen array
	root_margin:      wj.JSValue,   // the browser's serialization
	scroll_margin:    wj.JSValue,
	delay:            i32,
	track_visibility: bool,
	slot:             i32,
	pin:              u32,          // web_pin token
}

@(private = "file") io_slots: [^]wj.JSValue
@(private = "file") io_slot_cap: i32

@(private = "file") iface_io := i32(-2)
@(private = "file") iface_ioe := i32(-2)
@(private = "file") iface_document := i32(-2)
@(private = "file") iface_intersection_observer :: proc "c" () -> i32 { if iface_io == -2 { iface_io = wj.iface("IntersectionObserver") }; return iface_io }
@(private = "file") iface_io_entry :: proc "c" () -> i32 { if iface_ioe == -2 { iface_ioe = wj.iface("IntersectionObserverEntry") }; return iface_ioe }
@(private = "file") iface_doc :: proc "c" () -> i32 { if iface_document == -2 { iface_document = wj.iface("Document") }; return iface_document }

@(private = "file")
io_free :: proc "c" (p: rawptr) {
	m := (^IO_Impl)(p)
	rt := wj.the_runtime(wj.wj_the_realm.ctx)
	if m.slot > 0 && m.slot < io_slot_cap { io_slots[m.slot] = wj.UNDEFINED }
	if m.host != 0 { wj.wr_Object_release(m.host) }
	wj.JS_FreeValueRT(rt, m.callback)
	wj.JS_FreeValueRT(rt, m.root)
	wj.JS_FreeValueRT(rt, m.thresholds)
	wj.JS_FreeValueRT(rt, m.root_margin)
	wj.JS_FreeValueRT(rt, m.scroll_margin)
	wj.libc_free(m)
}

@(private = "file")
io_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	m := (^IO_Impl)(p)
	wj.wj_mark(rt, m.callback, mark_func)
	wj.wj_mark(rt, m.root, mark_func)
	wj.wj_mark(rt, m.thresholds, mark_func)
	wj.wj_mark(rt, m.root_margin, mark_func)
	wj.wj_mark(rt, m.scroll_margin, mark_func)
}

@(private = "file")
io_of :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^IO_Impl {
	o := wj.wj_this(ctx, this_val, iface_intersection_observer())
	if o == nil { return nil }
	if o.impl == nil || o.impl_free != io_free { wj.wj_throw_type(ctx, "Illegal invocation"); return nil }
	return (^IO_Impl)(o.impl)
}

@(private = "file")
io_sync_pin :: proc "c" (ctx: ^wj.Context, m: ^IO_Impl, self: wj.JSValue) {
	n := wj.wr_IntersectionObserver_observed(m.host)
	if n > 0 && m.pin == 0 { m.pin = wj.web_pin(ctx, self) }
	else if n == 0 && m.pin != 0 { wj.web_unpin(ctx, m.pin); m.pin = 0 }
}

// ---- entries ----

IE :: enum i32 { Time = 0, Root_Bounds = 1, Bounding = 2, Intersection = 3, Is_Intersecting = 4, Is_Visible = 5, Ratio = 6, Target = 7 }
IE_COUNT :: 8
IO_RECORD_BYTES :: 8 + 8 + 8 + 8 + 12 * 8   // see api/js_observers.widl

// An entry object with its eight values (taken); its prototype that of new_target when given.
@(private = "file")
entry_new :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, values: ^[IE_COUNT]wj.JSValue) -> wj.JSValue {
	d: ^wj.Dom_Impl
	bad := false
	for i in 0..<IE_COUNT { if wj.is_exception(values[i]) { bad = true } }
	e := bad ? wj.EXCEPTION : wj.dom_new(ctx, iface_io_entry(), wj.DOM_VALUES, wj.UNDEFINED, 0, &d)
	if wj.is_exception(e) {
		for i in 0..<IE_COUNT { wj.JS_FreeValue(ctx, values[i]) }
		return wj.EXCEPTION
	}
	d.values = ([^]wj.JSValue)(wj.libc_malloc(IE_COUNT * size_of(wj.JSValue)))
	if d.values == nil {
		for i in 0..<IE_COUNT { wj.JS_FreeValue(ctx, values[i]) }
		wj.JS_FreeValue(ctx, e)
		return wj.JS_ThrowOutOfMemory(ctx)
	}
	wj.memcpy(d.values, &values[0], IE_COUNT * size_of(wj.JSValue))
	d.n_values = IE_COUNT
	if wj.is_object(new_target) {
		proto := wj.JS_GetPropertyStr(ctx, new_target, "prototype")
		if wj.is_object(proto) { wj.JS_SetPrototype(ctx, e, proto) }
		wj.JS_FreeValue(ctx, proto)
	}
	return e
}

@(private = "file")
read_f64 :: proc "c" (p: [^]u8) -> f64 { return transmute(f64)wj.read_u64(p) }

@(private = "file")
rect_of :: proc "c" (ctx: ^wj.Context, p: [^]u8) -> wj.JSValue { return dom_rect_new(ctx, read_f64(p), read_f64(p[8:]), read_f64(p[16:]), read_f64(p[24:]), true) }

@(private = "file")
entry_from_record :: proc "c" (ctx: ^wj.Context, p: [^]u8) -> wj.JSValue {
	flags := wj.read_u32(p[24:])
	v: [IE_COUNT]wj.JSValue
	v[IE.Time] = wj.new_float64(ctx, read_f64(p[8:]))
	v[IE.Root_Bounds] = (flags & 4) != 0 ? rect_of(ctx, p[32:]) : wj.NULL
	v[IE.Bounding] = rect_of(ctx, p[64:])
	v[IE.Intersection] = rect_of(ctx, p[96:])
	v[IE.Is_Intersecting] = wj.new_bool((flags & 1) != 0)
	v[IE.Is_Visible] = wj.new_bool((flags & 2) != 0)
	v[IE.Ratio] = wj.new_float64(ctx, read_f64(p[16:]))
	v[IE.Target] = wj.wj_wrap_node(ctx, wj.read_u64(p))
	return entry_new(ctx, wj.UNDEFINED, &v)
}

// The records the browser queued, as an array of entries (it releases them). Exception pending: EXCEPTION.
@(private = "file")
take_entries :: proc "c" (ctx: ^wj.Context, m: ^IO_Impl) -> wj.JSValue {
	n := wj.wr_IntersectionObserver_takeRecords(m.host, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap {
		if wj.wj_scratch_grow(u32(n)) { n = wj.wr_IntersectionObserver_takeRecords(m.host, wj.wj_scratch.data, wj.wj_scratch.cap) }
	}
	arr := wj.JS_NewArray(ctx)
	if n < IO_RECORD_BYTES || wj.is_exception(arr) { return arr }
	buf := ([^]u8)(wj.libc_malloc(uint(n)))
	if buf == nil { wj.JS_FreeValue(ctx, arr); return wj.JS_ThrowOutOfMemory(ctx) }
	wj.memcpy(buf, wj.wj_scratch.data, uint(n))
	k := u32(0)
	result := arr
	off := i32(0)
	for off + IO_RECORD_BYTES <= n {
		e := entry_from_record(ctx, buf[off:])
		if wj.is_exception(e) { wj.JS_FreeValue(ctx, arr); result = wj.EXCEPTION; break }
		wj.array_set(ctx, arr, k, e); k += 1
		off += IO_RECORD_BYTES
	}
	wj.libc_free(buf)
	wj.wr_IntersectionObserver_release(m.host)
	return result
}

// ---- IntersectionObserver ----

Dlist :: struct { p: [^]f64, n: uint, cap: uint }

@(private = "file")
dlist_add :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	l := (^Dlist)(opaque)
	d: f64
	if !wj.wj_to_double(ctx, item, &d, true) { return false }
	if l.n == l.cap {
		cap := l.cap != 0 ? l.cap * 2 : 8
		q := ([^]f64)(wj.libc_realloc(l.p, cap * size_of(f64)))
		if q == nil { wj.JS_ThrowOutOfMemory(ctx); return false }
		l.p = q
		l.cap = cap
	}
	l.p[l.n] = d; l.n += 1
	return true
}

// The `threshold` member: a number, or a sequence of numbers, each in [0, 1]; sorted, at least one.
@(private = "file")
thresholds_of :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out: ^Dlist) -> bool {
	if wj.is_undefined(v) { return dlist_add(ctx, wj.new_int32(0), out) }
	it := wj.is_object(v) ? wj.web_is_iterable(ctx, v) : 0
	if it < 0 { return false }
	ok := it != 0 ? wj.web_for_of(ctx, v, dlist_add, out) : dlist_add(ctx, v, out)
	if !ok { return false }
	for i in 0..<out.n {
		if !(out.p[i] >= 0 && out.p[i] <= 1) {
			wj.JS_ThrowRangeError(ctx, "Failed to construct 'IntersectionObserver': Threshold values must be numbers between 0 and 1")
			return false
		}
	}
	if out.n == 0 { return dlist_add(ctx, wj.new_int32(0), out) }
	for i in 1..<out.n {   // insertion sort: a handful of thresholds
		x := out.p[i]
		j := i
		for j > 0 && out.p[j - 1] > x { out.p[j] = out.p[j - 1]; j -= 1 }
		out.p[j] = x
	}
	return true
}

@(private = "file")
string_result :: proc "c" (ctx: ^wj.Context, n: i32) -> wj.JSValue { return n > 0 ? wj.JS_NewStringLen(ctx, wj.wj_scratch.data, uint(n)) : wj.JS_NewString(ctx, "") }

@(export, link_name = "wjr_IntersectionObserver_constructor")
wjr_IntersectionObserver_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor IntersectionObserver requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "IntersectionObserver", 1, argc) }
	if !wj.JS_IsFunction(ctx, argv[0]) { return wj.wj_throw_type(ctx, "Failed to construct 'IntersectionObserver': The callback provided as parameter 1 is not a function.") }
	init: wjd_IntersectionObserverInit
	if !wjd_IntersectionObserverInit_from(ctx, wj.arg(argc, argv, 1), &init) { return wj.EXCEPTION }
	obj := wj.EXCEPTION
	th := Dlist{}
	root := u64(0)
	done := false
	if !wj.is_null(init.root) {
		r := wj.wj_unwrap(init.root, iface_element())
		if r == nil { r = wj.wj_unwrap(init.root, iface_doc()) }
		if r == nil || r.handle == 0 {
			wj.wj_throw_type(ctx, "Failed to construct 'IntersectionObserver': The provided value is not of type '(Element or Document)'.")
			done = true
		} else {
			root = r.handle
		}
	}
	if !done && !thresholds_of(ctx, init.threshold, &th) { done = true }
	if !done {
		slot := i32(1)
		for slot < io_slot_cap && !wj.is_undefined(io_slots[slot]) { slot += 1 }
		grew := true
		if slot >= io_slot_cap {
			cap := io_slot_cap != 0 ? io_slot_cap * 2 : 16
			s := ([^]wj.JSValue)(wj.libc_realloc(io_slots, uint(cap) * size_of(wj.JSValue)))
			if s == nil { wj.JS_ThrowOutOfMemory(ctx); grew = false }
			else { for i := io_slot_cap; i < cap; i += 1 { s[i] = wj.UNDEFINED }; io_slots = s; io_slot_cap = cap }
		}
		if grew {
			host := u64(0)
			th_bytes := th.n > 0 ? ([^]u8)(th.p) : nil
			st := wj.wr_IntersectionObserver_create(wj.table_index(rawptr(wj_cb_intersection)), slot, root,
				([^]u8)(rawptr(init.rootMargin.ptr)), u32(init.rootMargin.len),
				([^]u8)(rawptr(init.scrollMargin.ptr)), u32(init.scrollMargin.len),
				th_bytes, u32(th.n * size_of(f64)), &host)
			if st < 0 { wj.wj_throw_status(ctx, st, "IntersectionObserver") }
			else {
				m := (^IO_Impl)(wj.libc_calloc(1, size_of(IO_Impl)))
				if m == nil { wj.wr_Object_release(host); wj.JS_ThrowOutOfMemory(ctx) }
				else {
					m.host = host
					m.slot = slot
					m.callback = wj.JS_DupValue(ctx, argv[0])
					m.root = wj.JS_DupValue(ctx, init.root)
					m.delay = init.delay
					m.track_visibility = init.trackVisibility
					m.thresholds = wj.UNDEFINED
					m.root_margin = wj.UNDEFINED
					m.scroll_margin = wj.UNDEFINED
					n := wj.wr_IntersectionObserver_rootMargin(host, wj.wj_scratch.data, wj.wj_scratch.cap)
					if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_IntersectionObserver_rootMargin(host, wj.wj_scratch.data, wj.wj_scratch.cap) } }
					m.root_margin = string_result(ctx, n)
					n = wj.wr_IntersectionObserver_scrollMargin(host, wj.wj_scratch.data, wj.wj_scratch.cap)
					if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_IntersectionObserver_scrollMargin(host, wj.wj_scratch.data, wj.wj_scratch.cap) } }
					m.scroll_margin = string_result(ctx, n)
					m.thresholds = wj.JS_NewArray(ctx)
					for i in 0..<th.n { wj.array_set(ctx, m.thresholds, u32(i), wj.new_float64(ctx, th.p[i])) }
					if !wj.web_freeze(ctx, m.thresholds) { io_free(m) }
					else {
						obj = wj.wj_new_object_for(ctx, iface_intersection_observer(), new_target, m, io_free)
						if !wj.is_exception(obj) {
							wj.obj_of(obj).impl_mark = io_mark
							io_slots[slot] = obj
						}
					}
				}
			}
		}
	}
	wj.libc_free(th.p)
	wjd_IntersectionObserverInit_free(ctx, &init)
	return obj
}

@(export, link_name = "wjr_IntersectionObserver_observe")
wjr_IntersectionObserver_observe :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	m := io_of(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "IntersectionObserver.observe", 1, argc) }
	target: u64
	if !wj.wj_to_handle(ctx, argv[0], iface_element(), false, &target, "Failed to execute 'observe' on 'IntersectionObserver': parameter 1 is not of type 'Element'.") { return wj.EXCEPTION }
	st := wj.wr_IntersectionObserver_observe(m.host, target)
	if st < 0 { return wj.wj_throw_status(ctx, st, "IntersectionObserver.observe") }
	io_sync_pin(ctx, m, this_val)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_IntersectionObserver_unobserve")
wjr_IntersectionObserver_unobserve :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	m := io_of(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "IntersectionObserver.unobserve", 1, argc) }
	target: u64
	if !wj.wj_to_handle(ctx, argv[0], iface_element(), false, &target, "Failed to execute 'unobserve' on 'IntersectionObserver': parameter 1 is not of type 'Element'.") { return wj.EXCEPTION }
	wj.wr_IntersectionObserver_unobserve(m.host, target)
	io_sync_pin(ctx, m, this_val)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_IntersectionObserver_disconnect")
wjr_IntersectionObserver_disconnect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	m := io_of(ctx, this_val)
	if m == nil { return wj.EXCEPTION }
	wj.wr_IntersectionObserver_disconnect(m.host)
	io_sync_pin(ctx, m, this_val)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_IntersectionObserver_takeRecords")
wjr_IntersectionObserver_takeRecords :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	m := io_of(ctx, this_val)
	return m != nil ? take_entries(ctx, m) : wj.EXCEPTION
}

@(export, link_name = "wjr_IntersectionObserver_get_root")
wjr_IntersectionObserver_get_root :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { m := io_of(ctx, this_val); return m != nil ? wj.JS_DupValue(ctx, m.root) : wj.EXCEPTION }
@(export, link_name = "wjr_IntersectionObserver_get_rootMargin")
wjr_IntersectionObserver_get_rootMargin :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { m := io_of(ctx, this_val); return m != nil ? wj.JS_DupValue(ctx, m.root_margin) : wj.EXCEPTION }
@(export, link_name = "wjr_IntersectionObserver_get_scrollMargin")
wjr_IntersectionObserver_get_scrollMargin :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { m := io_of(ctx, this_val); return m != nil ? wj.JS_DupValue(ctx, m.scroll_margin) : wj.EXCEPTION }
@(export, link_name = "wjr_IntersectionObserver_get_thresholds")
wjr_IntersectionObserver_get_thresholds :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { m := io_of(ctx, this_val); return m != nil ? wj.JS_DupValue(ctx, m.thresholds) : wj.EXCEPTION }
@(export, link_name = "wjr_IntersectionObserver_get_delay")
wjr_IntersectionObserver_get_delay :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { m := io_of(ctx, this_val); return m != nil ? wj.new_int32(m.delay) : wj.EXCEPTION }
@(export, link_name = "wjr_IntersectionObserver_get_trackVisibility")
wjr_IntersectionObserver_get_trackVisibility :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { m := io_of(ctx, this_val); return m != nil ? wj.new_bool(m.track_visibility) : wj.EXCEPTION }

// ---- IntersectionObserverEntry ----

@(export, link_name = "wjr_IntersectionObserverEntry_constructor")
wjr_IntersectionObserverEntry_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor IntersectionObserverEntry requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "IntersectionObserverEntry", 1, argc) }
	init: wjd_IntersectionObserverEntryInit
	if !wjd_IntersectionObserverEntryInit_from(ctx, argv[0], &init) { return wj.EXCEPTION }
	v: [IE_COUNT]wj.JSValue
	for i in 0..<IE_COUNT { v[i] = wj.UNDEFINED }
	result := wj.EXCEPTION
	done := false
	if wj.wj_unwrap(init.target, iface_element()) == nil {
		wj.wj_throw_type(ctx, "Failed to construct 'IntersectionObserverEntry': member target is not of type 'Element'.")
		done = true
	}
	if !done {
		v[IE.Target] = wj.JS_DupValue(ctx, init.target)
		v[IE.Time] = wj.new_float64(ctx, init.time)
		if wj.is_null(init.rootBounds) {
			v[IE.Root_Bounds] = wj.NULL
		} else {
			r: wjd_DOMRectInit
			if !wjd_DOMRectInit_from(ctx, init.rootBounds, &r) { wj.JS_FreeValue(ctx, v[IE.Target]); done = true }
			else { v[IE.Root_Bounds] = dom_rect_new(ctx, r.x, r.y, r.width, r.height, true) }
		}
	}
	if !done {
		v[IE.Bounding] = dom_rect_new(ctx, init.boundingClientRect.x, init.boundingClientRect.y, init.boundingClientRect.width, init.boundingClientRect.height, true)
		v[IE.Intersection] = dom_rect_new(ctx, init.intersectionRect.x, init.intersectionRect.y, init.intersectionRect.width, init.intersectionRect.height, true)
		v[IE.Is_Intersecting] = wj.new_bool(init.isIntersecting)
		v[IE.Is_Visible] = wj.new_bool(init.isVisible)
		v[IE.Ratio] = wj.new_float64(ctx, init.intersectionRatio)
		result = entry_new(ctx, new_target, &v)
	}
	wjd_IntersectionObserverEntryInit_free(ctx, &init)
	return result
}

@(private = "file")
entry_field :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, i: i32) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, iface_io_entry())
	if d == nil { return wj.EXCEPTION }
	return i < i32(d.n_values) ? wj.JS_DupValue(ctx, d.values[i]) : wj.UNDEFINED
}

@(export, link_name = "wjr_IntersectionObserverEntry_get_time")
wjr_IntersectionObserverEntry_get_time :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(IE.Time)) }
@(export, link_name = "wjr_IntersectionObserverEntry_get_rootBounds")
wjr_IntersectionObserverEntry_get_rootBounds :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(IE.Root_Bounds)) }
@(export, link_name = "wjr_IntersectionObserverEntry_get_boundingClientRect")
wjr_IntersectionObserverEntry_get_boundingClientRect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(IE.Bounding)) }
@(export, link_name = "wjr_IntersectionObserverEntry_get_intersectionRect")
wjr_IntersectionObserverEntry_get_intersectionRect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(IE.Intersection)) }
@(export, link_name = "wjr_IntersectionObserverEntry_get_isIntersecting")
wjr_IntersectionObserverEntry_get_isIntersecting :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(IE.Is_Intersecting)) }
@(export, link_name = "wjr_IntersectionObserverEntry_get_isVisible")
wjr_IntersectionObserverEntry_get_isVisible :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(IE.Is_Visible)) }
@(export, link_name = "wjr_IntersectionObserverEntry_get_intersectionRatio")
wjr_IntersectionObserverEntry_get_intersectionRatio :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(IE.Ratio)) }
@(export, link_name = "wjr_IntersectionObserverEntry_get_target")
wjr_IntersectionObserverEntry_get_target :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_field(ctx, this_val, i32(IE.Target)) }

// The browser has entries for an observer (called from a task of the page): the script's callback gets them.
@(export, link_name = "wj_cb_intersection")
wj_cb_intersection :: proc "c" (user: i32) {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	if user <= 0 || user >= io_slot_cap || wj.is_undefined(io_slots[user]) { return }
	self := wj.JS_DupValue(ctx, io_slots[user])
	m := (^IO_Impl)(wj.obj_of(self).impl)
	entries := take_entries(ctx, m)
	if wj.is_exception(entries) {
		wj.wj_report_pending(ctx)
	} else {
		n := i64(0)
		wj.JS_GetLength(ctx, entries, &n)
		if n > 0 {
			args := [2]wj.JSValue{ entries, self }
			r := wj.JS_Call(ctx, m.callback, self, 2, &args[0])
			if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
		}
		wj.JS_FreeValue(ctx, entries)
	}
	wj.JS_FreeValue(ctx, self)
}
