// web_perf.odin: performance (High Resolution Time, Performance Timeline, User Timing) on the page's timeline (module
// performance: now(), timeOrigin, the user timing entries). Ported from native/js/runtime/web_perf.c: same wjr_*
// symbols, same exports (web_perf_preinit, wj_cb_timeline).
//
// The browser keeps the marks and measures (performance.max_user_timing_entries); entry objects are made on demand
// (getEntries* return new objects, as in browsers). A mark's or measure's `detail` is a structured clone kept here, by
// entry type, name and start time, so that getEntries() gives it back; clearMarks / clearMeasures forget it. The
// browser's own entries (navigation, resource, paint, event, long task, largest contentful paint, layout shift, element,
// visibility state, long animation frame) arrive as JSON (Performance_timeline); each parsed object is the data of an
// entry, whose attributes read its members, 0 or "" when it has none.
//
// PerformanceObserver (Performance Timeline 3): a registered observer is held here (the timeline's list of registered
// observers keeps it alive); each new entry goes to the buffer of the observers of its type, delivered by one task for
// all of them ("queue the PerformanceObserver task"). Unsupported types are ignored with a console warning, as browsers
// do.
//
// Every call into the browser is a declaration of api_decl/performance.odin through jsb.host.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") Kind :: api_decl.PerformanceEntryType
@(private = "file") Kinds :: bit_set[Kind; u32]
@(private = "file") none: abi.Nothing

// The kinds of the browser's timeline (the observers of these wake the realm).
@(private = "file") TIMELINE_KINDS :: Kinds{.Navigation, .Resource, .Paint, .Event, .First_Input, .Long_Task, .Largest_Contentful_Paint, .Layout_Shift, .Element, .Visibility_State, .Long_Animation_Frame}

@(private = "file")
KIND_NAMES := [Kind]cstring{
	.Any = "", .Mark = "mark", .Measure = "measure", .Navigation = "navigation", .Resource = "resource", .Paint = "paint",
	.Event = "event", .First_Input = "first-input", .Long_Task = "longtask", .Largest_Contentful_Paint = "largest-contentful-paint",
	.Layout_Shift = "layout-shift", .Element = "element", .Visibility_State = "visibility-state",
	.Long_Animation_Frame = "long-animation-frame", .Script = "script",
}

// The kind named `s`; false for a name that is none (Any has none).
@(private = "file")
kind_of :: proc "contextless" (s: string) -> (Kind, bool) {
	for k in Kind.Mark ..= Kind.Script { if string(KIND_NAMES[k]) == s { return k, true } }
	return .Any, false
}

// ---- the details of marks and measures, in a Map "type|start|name" -> detail (pre-initialized) ----

@(private = "file") details, map_get, map_set, map_delete: wj.JSValue

@(export, link_name = "web_perf_preinit")
web_perf_preinit :: proc "c" (ctx: ^wj.Context) -> i32 {
	src := "[new Map(), Map.prototype.get, Map.prototype.set, Map.prototype.delete]"
	v := wj.JS_Eval(ctx, raw_data(src), uint(len(src)), "<web>", wj.EVAL_TYPE_GLOBAL)
	if wj.is_exception(v) { return -1 }
	details = wj.JS_GetPropertyUint32(ctx, v, 0)
	map_get = wj.JS_GetPropertyUint32(ctx, v, 1)
	map_set = wj.JS_GetPropertyUint32(ctx, v, 2)
	map_delete = wj.JS_GetPropertyUint32(ctx, v, 3)
	wj.JS_FreeValue(ctx, v)
	return 0
}

@(private = "file")
detail_key :: proc(ctx: ^wj.Context, type: Kind, name: string, start: f64) -> wj.JSValue {
	head: [48]u8
	n := wj.snprintf(&head[0], len(head), "%d|%.17g|", i32(type), start)
	key := make([dynamic]u8, 0, int(n) + len(name), wj.libc_allocator())
	defer delete(key)
	append(&key, ..head[:n])
	append(&key, name)
	return wj.new_string_len(ctx, key[:])
}

@(private = "file")
make_performance :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	return wj.wj_wrap_owned(ctx, wj.wr_EventTarget_create(), ifc("Performance"), wj.UNDEFINED)
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_get_performance")
wjr_WindowOrWorkerGlobalScope_get_performance :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.web_singleton(ctx, wj.SINGLE_PERFORMANCE, make_performance)
}

// ---- entries ----

// `data` is the browser's own entry (navigation, resource, paint, event): the object its JSON parsed to, whose members
// the attributes read; undefined for marks and measures.
@(private = "file")
Entry :: struct {
	name:     wj.JSValue,
	detail:   wj.JSValue,
	data:     wj.JSValue,
	type:     Kind,
	start:    f64,
	duration: f64,
}

@(private = "file")
entry_free :: proc "c" (p: rawptr) {
	e := (^Entry)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, e.name)
	wj.JS_FreeValueRT(rt, e.detail)
	wj.JS_FreeValueRT(rt, e.data)
	wj.libc_free(e)
}

@(private = "file")
entry_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	e := (^Entry)(p)
	wj.wj_mark(rt, e.name, mark_func)
	wj.wj_mark(rt, e.detail, mark_func)
	wj.wj_mark(rt, e.data, mark_func)
}

// An entry on the libc heap (what entry_free frees), nil when out of memory.
@(private = "file")
entry_alloc :: proc "contextless" () -> ^Entry { return (^Entry)(wj.libc_calloc(1, size_of(Entry))) }

// A PerformanceMark or PerformanceMeasure object; takes name and detail.
@(private = "file")
entry_new :: proc "contextless" (ctx: ^wj.Context, new_target: wj.JSValue, type: Kind, name: wj.JSValue, start, duration: f64, detail: wj.JSValue) -> wj.JSValue {
	e := entry_alloc()
	if e == nil { wj.free_values(ctx, name, detail); return wj.JS_ThrowOutOfMemory(ctx) }
	e^ = {name = name, detail = detail, data = wj.UNDEFINED, type = type, start = start, duration = duration}
	obj := wj.wj_new_object_for(ctx, type == .Mark ? ifc("PerformanceMark") : ifc("PerformanceMeasure"), new_target, nil, nil)
	if wj.is_exception(obj) { entry_free(e); return obj }
	wj.web_set_impl(obj, e, entry_free, entry_mark)
	return obj
}

@(private = "file")
entry_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Entry {
	return (^Entry)(wj.this_impl(ctx, this_val, ifc("PerformanceEntry")))
}

@(export, link_name = "wjr_PerformanceEntry_get_name")
wjr_PerformanceEntry_get_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := entry_this(ctx, this_val)
	return e != nil ? wj.JS_DupValue(ctx, e.name) : wj.EXCEPTION
}
@(export, link_name = "wjr_PerformanceEntry_get_entryType")
wjr_PerformanceEntry_get_entryType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := entry_this(ctx, this_val)
	return e != nil ? wj.new_string(ctx, KIND_NAMES[e.type]) : wj.EXCEPTION
}
@(export, link_name = "wjr_PerformanceEntry_get_startTime")
wjr_PerformanceEntry_get_startTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := entry_this(ctx, this_val)
	return e != nil ? wj.new_float64(ctx, e.start) : wj.EXCEPTION
}
@(export, link_name = "wjr_PerformanceEntry_get_duration")
wjr_PerformanceEntry_get_duration :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := entry_this(ctx, this_val)
	return e != nil ? wj.new_float64(ctx, e.duration) : wj.EXCEPTION
}
@(export, link_name = "wjr_PerformanceEntry_get_id")
wjr_PerformanceEntry_get_id :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return entry_this(ctx, this_val) != nil ? wj.new_int32(0) : wj.EXCEPTION
}
@(export, link_name = "wjr_PerformanceEntry_get_navigationId")
wjr_PerformanceEntry_get_navigationId :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return entry_this(ctx, this_val) != nil ? wj.new_int32(0) : wj.EXCEPTION
}

@(private = "file")
detail_of :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32) -> wj.JSValue {
	e := (^Entry)(wj.this_impl(ctx, this_val, iface))
	return e != nil ? wj.JS_DupValue(ctx, e.detail) : wj.EXCEPTION
}
@(export, link_name = "wjr_PerformanceMark_get_detail")
wjr_PerformanceMark_get_detail :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return detail_of(ctx, this_val, ifc("PerformanceMark")) }
@(export, link_name = "wjr_PerformanceMeasure_get_detail")
wjr_PerformanceMeasure_get_detail :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return detail_of(ctx, this_val, ifc("PerformanceMeasure")) }

// The members of a browser entry (data) as a plain object, which is what toJSON() gives.
@(private = "file")
timeline_json :: proc "contextless" (ctx: ^wj.Context, e: ^Entry) -> wj.JSValue {
	src := "((d, t) => { const o = {}; for (const k in d) if (k !== 'seq') o[k] = d[k]; o.entryType = t; return o; })"
	f := wj.JS_Eval(ctx, raw_data(src), uint(len(src)), "<performance>", wj.EVAL_TYPE_GLOBAL)
	if wj.is_exception(f) { return f }
	args := [2]wj.JSValue{e.data, wj.new_string(ctx, KIND_NAMES[e.type])}
	r := wj.JS_Call(ctx, f, wj.UNDEFINED, 2, &args[0])
	wj.free_values(ctx, args[1], f)
	return r
}

@(export, link_name = "wjr_PerformanceEntry_toJSON")
wjr_PerformanceEntry_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	e := entry_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	if !wj.is_undefined(e.data) { return timeline_json(ctx, e) }
	o := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, o, "name", wj.JS_DupValue(ctx, e.name))
	wj.JS_SetPropertyStr(ctx, o, "entryType", wj.new_string(ctx, KIND_NAMES[e.type]))
	wj.JS_SetPropertyStr(ctx, o, "startTime", wj.new_float64(ctx, e.start))
	wj.JS_SetPropertyStr(ctx, o, "duration", wj.new_float64(ctx, e.duration))
	wj.JS_SetPropertyStr(ctx, o, "detail", wj.JS_DupValue(ctx, e.detail))
	return o
}

// ---- the browser's own entries: navigation, resource, paint, event timing ... ----

// The interface of an entry made from the browser's JSON of `kind`.
@(private = "file")
timeline_iface :: proc "contextless" (kind: Kind) -> i32 {
	#partial switch kind {
	case .Navigation:               return ifc("PerformanceNavigationTiming")
	case .Resource:                 return ifc("PerformanceResourceTiming")
	case .Paint:                    return ifc("PerformancePaintTiming")
	case .Event, .First_Input:      return ifc("PerformanceEventTiming")
	case .Long_Task:                return ifc("PerformanceLongTaskTiming")
	case .Largest_Contentful_Paint: return ifc("LargestContentfulPaint")
	case .Layout_Shift:             return ifc("LayoutShift")
	case .Element:                  return ifc("PerformanceElementTiming")
	case .Visibility_State:         return ifc("VisibilityStateEntry")
	case .Long_Animation_Frame:     return ifc("PerformanceLongAnimationFrameTiming")
	case .Script:                   return ifc("PerformanceScriptTiming")
	}
	return -1
}

// An entry object over the browser's JSON object `data` (taken).
@(private = "file")
timeline_entry_new :: proc "contextless" (ctx: ^wj.Context, kind: Kind, data: wj.JSValue) -> wj.JSValue {
	e := entry_alloc()
	if e == nil { wj.JS_FreeValue(ctx, data); return wj.JS_ThrowOutOfMemory(ctx) }
	nm := wj.JS_GetPropertyStr(ctx, data, "name")
	st := wj.JS_GetPropertyStr(ctx, data, "startTime")
	du := wj.JS_GetPropertyStr(ctx, data, "duration")
	if !wj.is_string(nm) { wj.JS_FreeValue(ctx, nm); nm = wj.new_string(ctx, "") }
	e^ = {name = nm, detail = wj.NULL, data = data, type = kind}
	if wj.is_number(st) { wj.JS_ToFloat64(ctx, &e.start, st) }
	if wj.is_number(du) { wj.JS_ToFloat64(ctx, &e.duration, du) }
	wj.free_values(ctx, st, du)
	obj := wj.wj_new_object_for(ctx, timeline_iface(kind), wj.UNDEFINED, nil, nil)
	if wj.is_exception(obj) { entry_free(e); return obj }
	wj.web_set_impl(obj, e, entry_free, entry_mark)
	return obj
}

// The entries of `kind` from sequence number `from` as the objects of the browser's JSON (an array); next gets the number
// after the last of them.
@(private = "file")
timeline_data :: proc(ctx: ^wj.Context, kind: Kind, from: u64, next: ^u64) -> wj.JSValue {
	text: string
	jsb.host(&text, api_decl.Performance_timeline, wj.wr_Performance_timeline, kind, from)
	if len(text) == 0 { return wj.JS_NewArray(ctx) }
	arr := wj.JS_ParseJSON(ctx, raw_data(text), uint(len(text)), "<timeline>")
	if wj.is_exception(arr) { return arr }
	if next != nil {
		n: i64
		wj.JS_GetLength(ctx, arr, &n)
		if n > 0 {
			last := wj.JS_GetPropertyInt64(ctx, arr, n - 1)
			seq := wj.JS_GetPropertyStr(ctx, last, "seq")
			d: f64
			if wj.is_number(seq) && wj.JS_ToFloat64(ctx, &d, seq) == 0 { next^ = u64(d) + 1 }
			wj.free_values(ctx, seq, last)
		}
	}
	return arr
}

// The entries of `kind` as objects.
@(private = "file")
timeline_entries :: proc(ctx: ^wj.Context, kind: Kind, from: u64, next: ^u64) -> wj.JSValue {
	data := timeline_data(ctx, kind, from, next)
	if wj.is_exception(data) { return data }
	out := wj.JS_NewArray(ctx)
	n: i64
	wj.JS_GetLength(ctx, data, &n)
	for i in 0 ..< n {
		e := timeline_entry_new(ctx, kind, wj.JS_GetPropertyInt64(ctx, data, i))
		if wj.is_exception(e) { wj.free_values(ctx, data, out); return e }
		wj.array_set(ctx, out, u32(i), e)
	}
	wj.JS_FreeValue(ctx, data)
	return out
}

// The member `key` of the entry's data when it is a number, else 0.
@(private = "file")
tl_num :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, key: cstring) -> wj.JSValue {
	e := entry_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	v := wj.is_undefined(e.data) ? wj.UNDEFINED : wj.JS_GetPropertyStr(ctx, e.data, key)
	if wj.is_number(v) { return v }
	wj.JS_FreeValue(ctx, v)
	return wj.new_float64(ctx, 0)
}

// The member `key` when it is a string, else "".
@(private = "file")
tl_str :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, key: cstring) -> wj.JSValue {
	e := entry_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	v := wj.is_undefined(e.data) ? wj.UNDEFINED : wj.JS_GetPropertyStr(ctx, e.data, key)
	if wj.is_string(v) { return v }
	wj.JS_FreeValue(ctx, v)
	return wj.new_string(ctx, "")
}

@(private = "file")
tl_bool :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, key: cstring) -> wj.JSValue {
	e := entry_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	v := wj.is_undefined(e.data) ? wj.UNDEFINED : wj.JS_GetPropertyStr(ctx, e.data, key)
	r := wj.new_bool(wj.JS_ToBool(ctx, v) != 0)
	wj.JS_FreeValue(ctx, v)
	return r
}

// The member `key` as an unsigned integer (size, naturalWidth, naturalHeight, sourceLine...).
@(private = "file")
tl_ulong :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, key: cstring) -> wj.JSValue {
	v := tl_num(ctx, this_val, key)
	if !wj.is_number(v) { return v }
	d: f64
	wj.JS_ToFloat64(ctx, &d, v)
	wj.JS_FreeValue(ctx, v)
	return wj.new_int64(ctx, i64(max(d, 0)))
}

@(private = "file")
tl_to_json :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := entry_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	return wj.is_undefined(e.data) ? wj.JS_NewObject(ctx) : timeline_json(ctx, e)
}

// PerformanceResourceTiming
@(export, link_name = "wjr_PerformanceResourceTiming_get_initiatorType")      wjr_PerformanceResourceTiming_get_initiatorType      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "initiatorType") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_deliveryType")       wjr_PerformanceResourceTiming_get_deliveryType       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "deliveryType") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_nextHopProtocol")    wjr_PerformanceResourceTiming_get_nextHopProtocol    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "nextHopProtocol") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_workerStart")        wjr_PerformanceResourceTiming_get_workerStart        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "workerStart") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_redirectStart")      wjr_PerformanceResourceTiming_get_redirectStart      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "redirectStart") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_redirectEnd")        wjr_PerformanceResourceTiming_get_redirectEnd        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "redirectEnd") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_fetchStart")         wjr_PerformanceResourceTiming_get_fetchStart         :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "fetchStart") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_domainLookupStart")  wjr_PerformanceResourceTiming_get_domainLookupStart  :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "domainLookupStart") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_domainLookupEnd")    wjr_PerformanceResourceTiming_get_domainLookupEnd    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "domainLookupEnd") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_connectStart")       wjr_PerformanceResourceTiming_get_connectStart       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "connectStart") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_connectEnd")         wjr_PerformanceResourceTiming_get_connectEnd         :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "connectEnd") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_secureConnectionStart") wjr_PerformanceResourceTiming_get_secureConnectionStart :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "secureConnectionStart") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_requestStart")       wjr_PerformanceResourceTiming_get_requestStart       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "requestStart") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_finalResponseHeadersStart") wjr_PerformanceResourceTiming_get_finalResponseHeadersStart :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "responseStart") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_firstInterimResponseStart") wjr_PerformanceResourceTiming_get_firstInterimResponseStart :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "firstInterimResponseStart") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_responseStart")      wjr_PerformanceResourceTiming_get_responseStart      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "responseStart") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_responseEnd")        wjr_PerformanceResourceTiming_get_responseEnd        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "responseEnd") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_transferSize")       wjr_PerformanceResourceTiming_get_transferSize       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "transferSize") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_encodedBodySize")    wjr_PerformanceResourceTiming_get_encodedBodySize    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "encodedBodySize") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_decodedBodySize")    wjr_PerformanceResourceTiming_get_decodedBodySize    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "decodedBodySize") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_responseStatus")     wjr_PerformanceResourceTiming_get_responseStatus     :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "responseStatus") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_renderBlockingStatus") wjr_PerformanceResourceTiming_get_renderBlockingStatus :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "renderBlockingStatus") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_contentType")        wjr_PerformanceResourceTiming_get_contentType        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "contentType") }
@(export, link_name = "wjr_PerformanceResourceTiming_get_contentEncoding")    wjr_PerformanceResourceTiming_get_contentEncoding    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "contentEncoding") }
@(export, link_name = "wjr_PerformanceResourceTiming_toJSON")                 wjr_PerformanceResourceTiming_toJSON                 :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tl_to_json(ctx, this_val) }

// PerformanceNavigationTiming
@(export, link_name = "wjr_PerformanceNavigationTiming_get_unloadEventStart")  wjr_PerformanceNavigationTiming_get_unloadEventStart  :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "unloadEventStart") }
@(export, link_name = "wjr_PerformanceNavigationTiming_get_unloadEventEnd")    wjr_PerformanceNavigationTiming_get_unloadEventEnd    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "unloadEventEnd") }
@(export, link_name = "wjr_PerformanceNavigationTiming_get_domInteractive")    wjr_PerformanceNavigationTiming_get_domInteractive    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "domInteractive") }
@(export, link_name = "wjr_PerformanceNavigationTiming_get_domContentLoadedEventStart") wjr_PerformanceNavigationTiming_get_domContentLoadedEventStart :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "domContentLoadedEventStart") }
@(export, link_name = "wjr_PerformanceNavigationTiming_get_domContentLoadedEventEnd")   wjr_PerformanceNavigationTiming_get_domContentLoadedEventEnd   :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "domContentLoadedEventEnd") }
@(export, link_name = "wjr_PerformanceNavigationTiming_get_domComplete")       wjr_PerformanceNavigationTiming_get_domComplete       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "domComplete") }
@(export, link_name = "wjr_PerformanceNavigationTiming_get_loadEventStart")    wjr_PerformanceNavigationTiming_get_loadEventStart    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "loadEventStart") }
@(export, link_name = "wjr_PerformanceNavigationTiming_get_loadEventEnd")      wjr_PerformanceNavigationTiming_get_loadEventEnd      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "loadEventEnd") }
@(export, link_name = "wjr_PerformanceNavigationTiming_get_type")              wjr_PerformanceNavigationTiming_get_type              :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "type") }
@(export, link_name = "wjr_PerformanceNavigationTiming_get_redirectCount")     wjr_PerformanceNavigationTiming_get_redirectCount     :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "redirectCount") }
@(export, link_name = "wjr_PerformanceNavigationTiming_get_criticalCHRestart") wjr_PerformanceNavigationTiming_get_criticalCHRestart :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "criticalCHRestart") }
@(export, link_name = "wjr_PerformanceNavigationTiming_toJSON")                wjr_PerformanceNavigationTiming_toJSON                :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tl_to_json(ctx, this_val) }

// PerformanceEventTiming
@(export, link_name = "wjr_PerformanceEventTiming_get_processingStart") wjr_PerformanceEventTiming_get_processingStart :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "processingStart") }
@(export, link_name = "wjr_PerformanceEventTiming_get_processingEnd")   wjr_PerformanceEventTiming_get_processingEnd   :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "processingEnd") }
@(export, link_name = "wjr_PerformanceEventTiming_get_cancelable")      wjr_PerformanceEventTiming_get_cancelable      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_bool(ctx, this_val, "cancelable") }
@(export, link_name = "wjr_PerformanceEventTiming_get_target")          wjr_PerformanceEventTiming_get_target          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_this(ctx, this_val) != nil ? wj.NULL : wj.EXCEPTION }
@(export, link_name = "wjr_PerformanceEventTiming_get_interactionId")   wjr_PerformanceEventTiming_get_interactionId   :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "interactionId") }
@(export, link_name = "wjr_PerformanceEventTiming_toJSON")              wjr_PerformanceEventTiming_toJSON              :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tl_to_json(ctx, this_val) }

// PerformanceLongTaskTiming (Long Tasks): a task of the page that took 50 ms or more; its attribution is one
// TaskAttributionTiming that says only "the window" (the browser does not tell which frame's script it was), kept as the
// entry's FrozenArray in its unused `detail`.
@(export, link_name = "wjr_PerformanceLongTaskTiming_get_startTime") wjr_PerformanceLongTaskTiming_get_startTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_startTime(ctx, this_val) }
@(export, link_name = "wjr_PerformanceLongTaskTiming_get_duration")  wjr_PerformanceLongTaskTiming_get_duration  :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_duration(ctx, this_val) }
@(export, link_name = "wjr_PerformanceLongTaskTiming_get_name")      wjr_PerformanceLongTaskTiming_get_name      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_name(ctx, this_val) }
@(export, link_name = "wjr_PerformanceLongTaskTiming_get_entryType") wjr_PerformanceLongTaskTiming_get_entryType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_entryType(ctx, this_val) }
@(export, link_name = "wjr_PerformanceLongTaskTiming_toJSON")        wjr_PerformanceLongTaskTiming_toJSON        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tl_to_json(ctx, this_val) }

@(export, link_name = "wjr_PerformanceLongTaskTiming_get_attribution")
wjr_PerformanceLongTaskTiming_get_attribution :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := (^Entry)(wj.this_impl(ctx, this_val, ifc("PerformanceLongTaskTiming")))
	if e == nil { return wj.EXCEPTION }
	if wj.JS_IsArray(e.detail) { return wj.JS_DupValue(ctx, e.detail) }
	arr := wj.JS_NewArray(ctx)
	a := wj.wj_new_object(ctx, ifc("TaskAttributionTiming"), nil, nil)
	if wj.is_exception(arr) || wj.is_exception(a) { wj.JS_FreeValue(ctx, arr); return a }
	wj.array_set(ctx, arr, 0, a)
	if !wj.web_freeze(ctx, arr) { wj.JS_FreeValue(ctx, arr); return wj.EXCEPTION }
	wj.JS_FreeValue(ctx, e.detail)
	e.detail = wj.JS_DupValue(ctx, arr)
	return arr
}

@(private = "file")
attribution_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> bool {
	return wj.wj_this(ctx, this_val, ifc("TaskAttributionTiming")) != nil
}
@(export, link_name = "wjr_TaskAttributionTiming_get_startTime")     wjr_TaskAttributionTiming_get_startTime     :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return attribution_this(ctx, this_val) ? wj.new_float64(ctx, 0) : wj.EXCEPTION }
@(export, link_name = "wjr_TaskAttributionTiming_get_duration")      wjr_TaskAttributionTiming_get_duration      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return attribution_this(ctx, this_val) ? wj.new_float64(ctx, 0) : wj.EXCEPTION }
@(export, link_name = "wjr_TaskAttributionTiming_get_name")          wjr_TaskAttributionTiming_get_name          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return attribution_this(ctx, this_val) ? wj.new_string(ctx, "unknown") : wj.EXCEPTION }
@(export, link_name = "wjr_TaskAttributionTiming_get_entryType")     wjr_TaskAttributionTiming_get_entryType     :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return attribution_this(ctx, this_val) ? wj.new_string(ctx, "taskattribution") : wj.EXCEPTION }
@(export, link_name = "wjr_TaskAttributionTiming_get_containerType") wjr_TaskAttributionTiming_get_containerType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return attribution_this(ctx, this_val) ? wj.new_string(ctx, "window") : wj.EXCEPTION }
@(export, link_name = "wjr_TaskAttributionTiming_get_containerSrc")  wjr_TaskAttributionTiming_get_containerSrc  :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return attribution_this(ctx, this_val) ? wj.new_string(ctx, "") : wj.EXCEPTION }
@(export, link_name = "wjr_TaskAttributionTiming_get_containerId")   wjr_TaskAttributionTiming_get_containerId   :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return attribution_this(ctx, this_val) ? wj.new_string(ctx, "") : wj.EXCEPTION }
@(export, link_name = "wjr_TaskAttributionTiming_get_containerName") wjr_TaskAttributionTiming_get_containerName :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return attribution_this(ctx, this_val) ? wj.new_string(ctx, "") : wj.EXCEPTION }

@(export, link_name = "wjr_TaskAttributionTiming_toJSON")
wjr_TaskAttributionTiming_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !attribution_this(ctx, this_val) { return wj.EXCEPTION }
	o := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, o, "name", wj.new_string(ctx, "unknown"))
	wj.JS_SetPropertyStr(ctx, o, "entryType", wj.new_string(ctx, "taskattribution"))
	wj.JS_SetPropertyStr(ctx, o, "startTime", wj.new_float64(ctx, 0))
	wj.JS_SetPropertyStr(ctx, o, "duration", wj.new_float64(ctx, 0))
	wj.JS_SetPropertyStr(ctx, o, "containerType", wj.new_string(ctx, "window"))
	wj.JS_SetPropertyStr(ctx, o, "containerSrc", wj.new_string(ctx, ""))
	wj.JS_SetPropertyStr(ctx, o, "containerId", wj.new_string(ctx, ""))
	wj.JS_SetPropertyStr(ctx, o, "containerName", wj.new_string(ctx, ""))
	return o
}

// PerformancePaintTiming
@(export, link_name = "wjr_PerformancePaintTiming_get_paintTime")        wjr_PerformancePaintTiming_get_paintTime        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "startTime") }
@(export, link_name = "wjr_PerformancePaintTiming_get_presentationTime") wjr_PerformancePaintTiming_get_presentationTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "startTime") }
@(export, link_name = "wjr_PerformancePaintTiming_toJSON")               wjr_PerformancePaintTiming_toJSON               :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tl_to_json(ctx, this_val) }

// ---- Largest Contentful Paint, Element Timing, Layout Instability, visibility-state ----
// The browser gives the plain members as JSON (renderTime, loadTime, size, id, url...); the live element (and a layout
// shift's source nodes) comes from Performance_timelineNode, which wraps a node that is still in the document or returns
// 0. The entry's sequence number is kept in its data as "seq".

@(private = "file")
entry_seq :: proc "contextless" (ctx: ^wj.Context, e: ^Entry) -> u64 {
	if wj.is_undefined(e.data) { return 0 }
	s := wj.JS_GetPropertyStr(ctx, e.data, "seq")
	d: f64
	if wj.is_number(s) { wj.JS_ToFloat64(ctx, &d, s) }
	wj.JS_FreeValue(ctx, s)
	return u64(d)
}

// The wrapper of the node timeline member `index` of this entry (0: the entry's own element), or null.
@(private = "file")
entry_node :: proc(ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, kind: Kind, index: u32) -> wj.JSValue {
	e := (^Entry)(wj.this_impl(ctx, this_val, iface))
	if e == nil { return wj.EXCEPTION }
	node: api_decl.Node
	jsb.host(&node, api_decl.Performance_timelineNode, wj.wr_Performance_timelineNode, kind, entry_seq(ctx, e), index)
	return node != 0 ? wj.wj_wrap_node(ctx, u64(node)) : wj.NULL
}

// A DOMRectReadOnly from the four numbers `key` packs (x, y, width, height); a zero rect when absent.
@(private = "file")
tl_rect :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, key: cstring) -> wj.JSValue {
	e := entry_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	v: [4]f64
	if !wj.is_undefined(e.data) { rect_numbers(ctx, wj.JS_GetPropertyStr(ctx, e.data, key), &v) }
	return dom_rect_new(ctx, v[0], v[1], v[2], v[3], true)
}

// The numbers of a four-element array (taken); zeros when it is none.
@(private = "file")
rect_numbers :: proc "contextless" (ctx: ^wj.Context, arr: wj.JSValue, v: ^[4]f64) {
	if wj.JS_IsArray(arr) {
		for i in 0 ..< 4 {
			n := wj.JS_GetPropertyUint32(ctx, arr, u32(i))
			if wj.is_number(n) { wj.JS_ToFloat64(ctx, &v[i], n) }
			wj.JS_FreeValue(ctx, n)
		}
	}
	wj.JS_FreeValue(ctx, arr)
}

@(export, link_name = "wjr_LargestContentfulPaint_get_renderTime")       wjr_LargestContentfulPaint_get_renderTime       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "renderTime") }
@(export, link_name = "wjr_LargestContentfulPaint_get_loadTime")         wjr_LargestContentfulPaint_get_loadTime         :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "loadTime") }
@(export, link_name = "wjr_LargestContentfulPaint_get_size")             wjr_LargestContentfulPaint_get_size             :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_ulong(ctx, this_val, "size") }
@(export, link_name = "wjr_LargestContentfulPaint_get_id")               wjr_LargestContentfulPaint_get_id               :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "id") }
@(export, link_name = "wjr_LargestContentfulPaint_get_url")              wjr_LargestContentfulPaint_get_url              :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "url") }
@(export, link_name = "wjr_LargestContentfulPaint_get_paintTime")        wjr_LargestContentfulPaint_get_paintTime        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "renderTime") }
@(export, link_name = "wjr_LargestContentfulPaint_get_presentationTime") wjr_LargestContentfulPaint_get_presentationTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "renderTime") }
@(export, link_name = "wjr_LargestContentfulPaint_toJSON")               wjr_LargestContentfulPaint_toJSON               :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tl_to_json(ctx, this_val) }
@(export, link_name = "wjr_LargestContentfulPaint_get_element")
wjr_LargestContentfulPaint_get_element :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return entry_node(ctx, this_val, ifc("LargestContentfulPaint"), .Largest_Contentful_Paint, 0)
}

@(export, link_name = "wjr_PerformanceElementTiming_get_renderTime")       wjr_PerformanceElementTiming_get_renderTime       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "renderTime") }
@(export, link_name = "wjr_PerformanceElementTiming_get_loadTime")         wjr_PerformanceElementTiming_get_loadTime         :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "loadTime") }
@(export, link_name = "wjr_PerformanceElementTiming_get_intersectionRect") wjr_PerformanceElementTiming_get_intersectionRect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_rect(ctx, this_val, "intersectRect") }
@(export, link_name = "wjr_PerformanceElementTiming_get_identifier")       wjr_PerformanceElementTiming_get_identifier       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "identifier") }
@(export, link_name = "wjr_PerformanceElementTiming_get_naturalWidth")     wjr_PerformanceElementTiming_get_naturalWidth     :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_ulong(ctx, this_val, "naturalWidth") }
@(export, link_name = "wjr_PerformanceElementTiming_get_naturalHeight")    wjr_PerformanceElementTiming_get_naturalHeight    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_ulong(ctx, this_val, "naturalHeight") }
@(export, link_name = "wjr_PerformanceElementTiming_get_id")               wjr_PerformanceElementTiming_get_id               :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "id") }
@(export, link_name = "wjr_PerformanceElementTiming_get_url")              wjr_PerformanceElementTiming_get_url              :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "url") }
@(export, link_name = "wjr_PerformanceElementTiming_get_paintTime")        wjr_PerformanceElementTiming_get_paintTime        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "renderTime") }
@(export, link_name = "wjr_PerformanceElementTiming_get_presentationTime") wjr_PerformanceElementTiming_get_presentationTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "renderTime") }
@(export, link_name = "wjr_PerformanceElementTiming_toJSON")               wjr_PerformanceElementTiming_toJSON               :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tl_to_json(ctx, this_val) }
@(export, link_name = "wjr_PerformanceElementTiming_get_element")
wjr_PerformanceElementTiming_get_element :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return entry_node(ctx, this_val, ifc("PerformanceElementTiming"), .Element, 0)
}

@(export, link_name = "wjr_LayoutShift_get_value")          wjr_LayoutShift_get_value          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "value") }
@(export, link_name = "wjr_LayoutShift_get_hadRecentInput") wjr_LayoutShift_get_hadRecentInput :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_bool(ctx, this_val, "hadRecentInput") }
@(export, link_name = "wjr_LayoutShift_get_lastInputTime")  wjr_LayoutShift_get_lastInputTime  :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "lastInputTime") }
@(export, link_name = "wjr_LayoutShift_toJSON")             wjr_LayoutShift_toJSON             :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tl_to_json(ctx, this_val) }

// LayoutShift.sources: a FrozenArray of LayoutShiftAttribution, made from the entry's "sources" (an array of {node (a
// handle string), previousRect, currentRect}); the node is wrapped live (null when it left the document). Kept in the
// entry's `detail` once made, like PerformanceLongTaskTiming.attribution.
@(export, link_name = "wjr_LayoutShift_get_sources")
wjr_LayoutShift_get_sources :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := (^Entry)(wj.this_impl(ctx, this_val, ifc("LayoutShift")))
	if e == nil { return wj.EXCEPTION }
	if wj.JS_IsArray(e.detail) { return wj.JS_DupValue(ctx, e.detail) }
	seq := entry_seq(ctx, e)
	arr := wj.JS_NewArray(ctx)
	if wj.is_exception(arr) { return arr }
	n: i64
	src := wj.is_undefined(e.data) ? wj.UNDEFINED : wj.JS_GetPropertyStr(ctx, e.data, "sources")
	if wj.JS_IsArray(src) { wj.JS_GetLength(ctx, src, &n) }
	for i in 0 ..< n {
		s := wj.JS_GetPropertyInt64(ctx, src, i)
		a := wj.wj_new_object(ctx, ifc("LayoutShiftAttribution"), nil, nil)
		if wj.is_exception(a) { wj.free_values(ctx, s, src, arr); return a }
		// the node and the two rects are kept on the attribution object as extras (read by its getters)
		node: api_decl.Node
		jsb.host(&node, api_decl.Performance_timelineNode, wj.wr_Performance_timelineNode, Kind.Layout_Shift, seq, u32(i))
		prev := wj.JS_GetPropertyStr(ctx, s, "previousRect")
		cur := wj.JS_GetPropertyStr(ctx, s, "currentRect")
		wj.web_extra_set(ctx, a, "node", node != 0 ? wj.wj_wrap_node(ctx, u64(node)) : wj.NULL)
		wj.web_extra_set(ctx, a, "prev", wj.JS_IsArray(prev) ? wj.JS_DupValue(ctx, prev) : wj.NULL)
		wj.web_extra_set(ctx, a, "cur", wj.JS_IsArray(cur) ? wj.JS_DupValue(ctx, cur) : wj.NULL)
		wj.free_values(ctx, prev, cur, s)
		wj.array_set(ctx, arr, u32(i), a)
	}
	wj.JS_FreeValue(ctx, src)
	if !wj.web_freeze(ctx, arr) { wj.JS_FreeValue(ctx, arr); return wj.EXCEPTION }
	wj.JS_FreeValue(ctx, e.detail)
	e.detail = wj.JS_DupValue(ctx, arr)
	return arr
}

@(private = "file")
attr_rect :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, key: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("LayoutShiftAttribution")) == nil { return wj.EXCEPTION }
	v: [4]f64
	rect_numbers(ctx, wj.web_extra_get(ctx, this_val, key), &v)
	return dom_rect_new(ctx, v[0], v[1], v[2], v[3], true)
}
@(export, link_name = "wjr_LayoutShiftAttribution_get_node")
wjr_LayoutShiftAttribution_get_node :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("LayoutShiftAttribution")) == nil { return wj.EXCEPTION }
	n := wj.web_extra_get(ctx, this_val, "node")
	if wj.is_object(n) { return n }
	wj.JS_FreeValue(ctx, n)
	return wj.NULL
}
@(export, link_name = "wjr_LayoutShiftAttribution_get_previousRect") wjr_LayoutShiftAttribution_get_previousRect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return attr_rect(ctx, this_val, "prev") }
@(export, link_name = "wjr_LayoutShiftAttribution_get_currentRect")  wjr_LayoutShiftAttribution_get_currentRect  :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return attr_rect(ctx, this_val, "cur") }

@(export, link_name = "wjr_VisibilityStateEntry_get_name")      wjr_VisibilityStateEntry_get_name      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_name(ctx, this_val) }
@(export, link_name = "wjr_VisibilityStateEntry_get_entryType") wjr_VisibilityStateEntry_get_entryType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_entryType(ctx, this_val) }
@(export, link_name = "wjr_VisibilityStateEntry_get_startTime") wjr_VisibilityStateEntry_get_startTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_startTime(ctx, this_val) }
@(export, link_name = "wjr_VisibilityStateEntry_get_duration")  wjr_VisibilityStateEntry_get_duration  :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_duration(ctx, this_val) }

// ---- Long Animation Frames ----
// The browser gives the frame as JSON (startTime, duration, renderStart, styleAndLayoutStart, styleDuration,
// layoutDuration, blockingDuration, firstUIEventTimestamp) with a nested "scripts" array; each script object has the
// members of PerformanceScriptTiming. The scripts FrozenArray is made on demand and kept in the entry's unused `detail`,
// like PerformanceLongTaskTiming.attribution. A PerformanceScriptTiming wraps one script object as its own data.

@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_startTime")           wjr_PerformanceLongAnimationFrameTiming_get_startTime           :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_startTime(ctx, this_val) }
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_duration")            wjr_PerformanceLongAnimationFrameTiming_get_duration            :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_duration(ctx, this_val) }
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_name")                wjr_PerformanceLongAnimationFrameTiming_get_name                :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_name(ctx, this_val) }
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_entryType")           wjr_PerformanceLongAnimationFrameTiming_get_entryType           :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_entryType(ctx, this_val) }
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_renderStart")         wjr_PerformanceLongAnimationFrameTiming_get_renderStart         :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "renderStart") }
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_styleAndLayoutStart") wjr_PerformanceLongAnimationFrameTiming_get_styleAndLayoutStart :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "styleAndLayoutStart") }
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_styleDuration")       wjr_PerformanceLongAnimationFrameTiming_get_styleDuration       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "styleDuration") }
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_layoutDuration")      wjr_PerformanceLongAnimationFrameTiming_get_layoutDuration      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "layoutDuration") }
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_blockingDuration")    wjr_PerformanceLongAnimationFrameTiming_get_blockingDuration    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "blockingDuration") }
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_firstUIEventTimestamp") wjr_PerformanceLongAnimationFrameTiming_get_firstUIEventTimestamp :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "firstUIEventTimestamp") }
// PaintTimingMixin on the LoAF entry: Wren times the frame by its loop clock, not a composited present, so paintTime is
// 0 (duration then runs to the frame end) and presentationTime is null, as the mixin allows.
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_paintTime")        wjr_PerformanceLongAnimationFrameTiming_get_paintTime        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_this(ctx, this_val) != nil ? wj.new_float64(ctx, 0) : wj.EXCEPTION }
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_presentationTime") wjr_PerformanceLongAnimationFrameTiming_get_presentationTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return entry_this(ctx, this_val) != nil ? wj.NULL : wj.EXCEPTION }
@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_toJSON")               wjr_PerformanceLongAnimationFrameTiming_toJSON               :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tl_to_json(ctx, this_val) }

@(export, link_name = "wjr_PerformanceLongAnimationFrameTiming_get_scripts")
wjr_PerformanceLongAnimationFrameTiming_get_scripts :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := (^Entry)(wj.this_impl(ctx, this_val, ifc("PerformanceLongAnimationFrameTiming")))
	if e == nil { return wj.EXCEPTION }
	if wj.JS_IsArray(e.detail) { return wj.JS_DupValue(ctx, e.detail) }
	arr := wj.JS_NewArray(ctx)
	if wj.is_exception(arr) { return arr }
	src := wj.is_undefined(e.data) ? wj.UNDEFINED : wj.JS_GetPropertyStr(ctx, e.data, "scripts")
	n: i64
	if wj.JS_IsArray(src) { wj.JS_GetLength(ctx, src, &n) }
	for i in 0 ..< n {
		s := wj.JS_GetPropertyInt64(ctx, src, i)   // the script's plain object becomes its entry's data
		so := timeline_entry_new(ctx, .Script, s)
		if wj.is_exception(so) { wj.free_values(ctx, src, arr); return so }
		wj.array_set(ctx, arr, u32(i), so)
	}
	wj.JS_FreeValue(ctx, src)
	if !wj.web_freeze(ctx, arr) { wj.JS_FreeValue(ctx, arr); return wj.EXCEPTION }
	wj.JS_FreeValue(ctx, e.detail)
	e.detail = wj.JS_DupValue(ctx, arr)
	return arr
}

// PerformanceScriptTiming: one script object (its own entry data). name and entryType are constant ("script").
@(export, link_name = "wjr_PerformanceScriptTiming_get_startTime")  wjr_PerformanceScriptTiming_get_startTime  :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_startTime(ctx, this_val) }
@(export, link_name = "wjr_PerformanceScriptTiming_get_duration")   wjr_PerformanceScriptTiming_get_duration   :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_duration(ctx, this_val) }
@(export, link_name = "wjr_PerformanceScriptTiming_get_name")       wjr_PerformanceScriptTiming_get_name       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "name") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_entryType")  wjr_PerformanceScriptTiming_get_entryType  :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wjr_PerformanceEntry_get_entryType(ctx, this_val) }
@(export, link_name = "wjr_PerformanceScriptTiming_get_invokerType") wjr_PerformanceScriptTiming_get_invokerType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "invokerType") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_invoker")    wjr_PerformanceScriptTiming_get_invoker    :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "invoker") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_executionStart") wjr_PerformanceScriptTiming_get_executionStart :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "executionStart") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_sourceURL")  wjr_PerformanceScriptTiming_get_sourceURL  :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "sourceURL") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_sourceFunctionName") wjr_PerformanceScriptTiming_get_sourceFunctionName :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "sourceFunctionName") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_sourceCharPosition") wjr_PerformanceScriptTiming_get_sourceCharPosition :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_whole(ctx, this_val, "sourceCharPosition") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_sourceLine") wjr_PerformanceScriptTiming_get_sourceLine :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_whole(ctx, this_val, "sourceLine") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_sourceColumn") wjr_PerformanceScriptTiming_get_sourceColumn :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_whole(ctx, this_val, "sourceColumn") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_pauseDuration") wjr_PerformanceScriptTiming_get_pauseDuration :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "pauseDuration") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_forcedStyleDuration") wjr_PerformanceScriptTiming_get_forcedStyleDuration :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "forcedStyleDuration") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_forcedLayoutDuration") wjr_PerformanceScriptTiming_get_forcedLayoutDuration :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_num(ctx, this_val, "forcedLayoutDuration") }
@(export, link_name = "wjr_PerformanceScriptTiming_get_windowAttribution") wjr_PerformanceScriptTiming_get_windowAttribution :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return tl_str(ctx, this_val, "windowAttribution") }
@(export, link_name = "wjr_PerformanceScriptTiming_toJSON")         wjr_PerformanceScriptTiming_toJSON         :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return tl_to_json(ctx, this_val) }

// A member read as a number and returned as a whole number (sourceLine...).
@(private = "file")
tl_whole :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, key: cstring) -> wj.JSValue {
	v := tl_num(ctx, this_val, key)
	if !wj.is_number(v) { return v }
	d: f64
	wj.JS_ToFloat64(ctx, &d, v)
	wj.JS_FreeValue(ctx, v)
	return wj.new_int64(ctx, i64(d))
}

@(export, link_name = "wjr_PerformanceScriptTiming_get_forcedStyleAndLayoutDuration")
wjr_PerformanceScriptTiming_get_forcedStyleAndLayoutDuration :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	a, b := tl_num(ctx, this_val, "forcedStyleDuration"), tl_num(ctx, this_val, "forcedLayoutDuration")
	x, y: f64
	if wj.is_number(a) { wj.JS_ToFloat64(ctx, &x, a) }
	if wj.is_number(b) { wj.JS_ToFloat64(ctx, &y, b) }
	wj.free_values(ctx, a, b)
	return wj.new_float64(ctx, x + y)
}

// The script's window: Wren has one window per page, so the script's window is this realm's window (the global).
@(export, link_name = "wjr_PerformanceScriptTiming_get_window")
wjr_PerformanceScriptTiming_get_window :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if entry_this(ctx, this_val) == nil { return wj.EXCEPTION }
	return wj.JS_GetGlobalObject(ctx)   // owned reference
}

// ---- User Timing: mark, measure, the entry queries ----

// The structured clone of a detail (null when absent).
@(private = "file")
clone_detail :: proc(ctx: ^wj.Context, opt: wj.JSValue, out: ^wj.JSValue) -> bool {
	out^ = wj.NULL
	d: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "detail", &d) { return false }
	if wj.is_undefined(d) || wj.is_null(d) { wj.JS_FreeValue(ctx, d); return true }
	n: uint
	p := web_clone_serialize(ctx, d, &n)
	wj.JS_FreeValue(ctx, d)
	if p == nil { return false }
	out^ = web_clone_deserialize(ctx, p, n)
	web_clone_free(ctx, p)
	return !wj.is_exception(out^)
}

@(private = "file")
remember_detail :: proc(ctx: ^wj.Context, type: Kind, name: string, start: f64, detail: wj.JSValue) {
	if wj.is_null(detail) { return }
	args := [2]wj.JSValue{detail_key(ctx, type, name, start), wj.JS_DupValue(ctx, detail)}
	r := wj.JS_Call(ctx, map_set, details, 2, &args[0])
	wj.free_values(ctx, r, args[0], args[1])
}

// PerformanceTiming's attributes in the interface's order (Performance_timingOf's index).
@(private = "file")
TIMING_NAMES := [?]cstring{
	"navigationStart", "unloadEventStart", "unloadEventEnd", "redirectStart", "redirectEnd", "fetchStart",
	"domainLookupStart", "domainLookupEnd", "connectStart", "connectEnd", "secureConnectionStart", "requestStart",
	"responseStart", "responseEnd", "domLoading", "domInteractive", "domContentLoadedEventStart",
	"domContentLoadedEventEnd", "domComplete", "loadEventStart", "loadEventEnd",
}

@(private = "file")
timing_index :: proc "contextless" (s: string) -> int {
	for name, i in TIMING_NAMES { if string(name) == s { return i } }
	return -1
}

// The attribute's value: whole milliseconds since the Unix epoch, 0 when that moment has not come.
@(private = "file")
timing_value :: proc(which: int) -> f64 {
	rel: f64
	jsb.host(&rel, api_decl.Performance_timingOf, wj.wr_Performance_timingOf, i32(which))
	if wj.is_nan(rel) { return 0 }
	origin: f64
	jsb.host(&origin, api_decl.Performance_timeOrigin, wj.wr_Performance_timeOrigin)
	return wj.floor(origin + rel)
}

// PerformanceMark constructor and performance.mark(): the entry, not recorded. name_out gets the name (converted).
@(private = "file")
mark_make :: proc(ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, name_out: ^wj.Str) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "PerformanceMark", 1, argc) }
	if !wj.wj_to_str(ctx, argv[0], name_out, 0, nil) { return wj.EXCEPTION }
	// a window's marks cannot take the name of a PerformanceTiming attribute (measure reads those as that moment)
	if wj.is_window() && timing_index(str_view(name_out^)) >= 0 {
		return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to construct 'PerformanceMark': the name is a PerformanceTiming attribute.")
	}
	opt := wj.arg(argc, argv, 1)
	if !wj.web_dict_check(ctx, opt, "PerformanceMark") { return wj.EXCEPTION }
	st: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "startTime", &st) { return wj.EXCEPTION }
	start: f64
	if wj.is_undefined(st) {
		jsb.host(&start, api_decl.Performance_now, wj.wr_Performance_now)
	} else {
		ok := wj.wj_to_double(ctx, st, &start, true)
		wj.JS_FreeValue(ctx, st)
		if !ok { return wj.EXCEPTION }
		if start < 0 { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'PerformanceMark': '%g' is negative.", start) }
	}
	detail: wj.JSValue
	if !clone_detail(ctx, opt, &detail) { return wj.EXCEPTION }
	return entry_new(ctx, new_target, .Mark, wj.new_string_len(ctx, str_view(name_out^)), start, 0, detail)
}

@(export, link_name = "wjr_PerformanceMark_constructor")
wjr_PerformanceMark_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor PerformanceMark requires 'new'") }
	name: wj.Str
	defer wj.wj_str_free(ctx, &name)
	return mark_make(ctx, new_target, argc, argv, &name)
}

@(private = "file")
perf_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> bool {
	return wj.wj_this(ctx, this_val, ifc("Performance")) != nil
}

@(export, link_name = "wjr_Performance_mark")
wjr_Performance_mark :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !perf_this(ctx, this_val) { return wj.EXCEPTION }
	name: wj.Str
	defer wj.wj_str_free(ctx, &name)
	m := mark_make(ctx, wj.UNDEFINED, argc, argv, &name)
	if wj.is_exception(m) { return m }
	e := (^Entry)(wj.obj_impl(m))
	if st := jsb.host(&none, api_decl.Performance_mark, wj.wr_Performance_mark, str_view(name), e.start); st != .None {
		wj.JS_FreeValue(ctx, m)
		if st == .Syntax { return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'mark' on 'Performance': the mark name is not valid.") }
		return wj.wj_throw_status(ctx, i32(st), "Performance.mark")
	}
	remember_detail(ctx, .Mark, str_view(name), e.start, e.detail)
	queue_entry(ctx, .Mark, m)
	return m
}

// ---- Navigation Timing 1: performance.timing ----

@(export, link_name = "wjr_Performance_get_timing")
wjr_Performance_get_timing :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if !perf_this(ctx, this_val) { return wj.EXCEPTION }
	// [SameObject]: kept with the Performance object
	t := wj.web_extra_get(ctx, this_val, "timing")
	if wj.is_object(t) { return t }
	wj.JS_FreeValue(ctx, t)
	t = wj.wj_new_object(ctx, ifc("PerformanceTiming"), nil, nil)
	if wj.is_exception(t) { return t }
	if !wj.web_extra_set(ctx, this_val, "timing", wj.JS_DupValue(ctx, t)) { wj.JS_FreeValue(ctx, t); return wj.EXCEPTION }
	return t
}

@(private = "file")
timing_get :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, which: int) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, ifc("PerformanceTiming")) == nil { return wj.EXCEPTION }
	return wj.new_float64(ctx, timing_value(which))
}

@(export, link_name = "wjr_PerformanceTiming_get_navigationStart")            wjr_PerformanceTiming_get_navigationStart            :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 0) }
@(export, link_name = "wjr_PerformanceTiming_get_unloadEventStart")           wjr_PerformanceTiming_get_unloadEventStart           :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 1) }
@(export, link_name = "wjr_PerformanceTiming_get_unloadEventEnd")             wjr_PerformanceTiming_get_unloadEventEnd             :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 2) }
@(export, link_name = "wjr_PerformanceTiming_get_redirectStart")              wjr_PerformanceTiming_get_redirectStart              :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 3) }
@(export, link_name = "wjr_PerformanceTiming_get_redirectEnd")                wjr_PerformanceTiming_get_redirectEnd                :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 4) }
@(export, link_name = "wjr_PerformanceTiming_get_fetchStart")                 wjr_PerformanceTiming_get_fetchStart                 :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 5) }
@(export, link_name = "wjr_PerformanceTiming_get_domainLookupStart")          wjr_PerformanceTiming_get_domainLookupStart          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 6) }
@(export, link_name = "wjr_PerformanceTiming_get_domainLookupEnd")            wjr_PerformanceTiming_get_domainLookupEnd            :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 7) }
@(export, link_name = "wjr_PerformanceTiming_get_connectStart")               wjr_PerformanceTiming_get_connectStart               :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 8) }
@(export, link_name = "wjr_PerformanceTiming_get_connectEnd")                 wjr_PerformanceTiming_get_connectEnd                 :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 9) }
@(export, link_name = "wjr_PerformanceTiming_get_secureConnectionStart")      wjr_PerformanceTiming_get_secureConnectionStart      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 10) }
@(export, link_name = "wjr_PerformanceTiming_get_requestStart")               wjr_PerformanceTiming_get_requestStart               :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 11) }
@(export, link_name = "wjr_PerformanceTiming_get_responseStart")              wjr_PerformanceTiming_get_responseStart              :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 12) }
@(export, link_name = "wjr_PerformanceTiming_get_responseEnd")                wjr_PerformanceTiming_get_responseEnd                :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 13) }
@(export, link_name = "wjr_PerformanceTiming_get_domLoading")                 wjr_PerformanceTiming_get_domLoading                 :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 14) }
@(export, link_name = "wjr_PerformanceTiming_get_domInteractive")             wjr_PerformanceTiming_get_domInteractive             :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 15) }
@(export, link_name = "wjr_PerformanceTiming_get_domContentLoadedEventStart") wjr_PerformanceTiming_get_domContentLoadedEventStart :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 16) }
@(export, link_name = "wjr_PerformanceTiming_get_domContentLoadedEventEnd")   wjr_PerformanceTiming_get_domContentLoadedEventEnd   :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 17) }
@(export, link_name = "wjr_PerformanceTiming_get_domComplete")                wjr_PerformanceTiming_get_domComplete                :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 18) }
@(export, link_name = "wjr_PerformanceTiming_get_loadEventStart")             wjr_PerformanceTiming_get_loadEventStart             :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 19) }
@(export, link_name = "wjr_PerformanceTiming_get_loadEventEnd")               wjr_PerformanceTiming_get_loadEventEnd               :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return timing_get(ctx, this_val, 20) }

@(export, link_name = "wjr_PerformanceTiming_toJSON")
wjr_PerformanceTiming_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, ifc("PerformanceTiming")) == nil { return wj.EXCEPTION }
	o := wj.JS_NewObject(ctx)
	for name, i in TIMING_NAMES { wj.JS_SetPropertyStr(ctx, o, name, wj.new_float64(ctx, timing_value(i))) }
	return o
}

// The start time of the latest mark named `v` (a string; a PerformanceTiming attribute's name stands for that moment),
// or `v` itself (a number): false with a SyntaxError / TypeError / InvalidAccessError pending.
@(private = "file")
time_of :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^f64) -> bool {
	if wj.is_number(v) {
		if !wj.wj_to_double(ctx, v, out, true) { return false }
		if out^ < 0 { wj.JS_ThrowTypeError(ctx, "Failed to execute 'measure' on 'Performance': a time is negative."); return false }
		return true
	}
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, nil) { return false }
	defer wj.wj_str_free(ctx, &s)
	if ti := timing_index(str_view(s)); ti >= 0 {
		// User Timing "convert a mark to a timestamp": the attribute relative to navigationStart
		if !wj.is_window() { wj.JS_ThrowTypeError(ctx, "Failed to execute 'measure' on 'Performance': '%s' is only defined in a window.", TIMING_NAMES[ti]); return false }
		t := timing_value(ti)
		if t == 0 {
			wj.wj_throw_dom(ctx, "InvalidAccessError", "Failed to execute 'measure' on 'Performance': that PerformanceTiming moment has not happened.")
			return false
		}
		out^ = t - timing_value(0)
		return true
	}
	n: i32
	jsb.host(&n, api_decl.Performance_entryCount, wj.wr_Performance_entryCount, str_view(s), Kind.Mark)
	if n <= 0 {
		wj.wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'measure' on 'Performance': The mark does not exist.")
		return false
	}
	jsb.host(out, api_decl.Performance_entryStartTime, wj.wr_Performance_entryStartTime, str_view(s), Kind.Mark, n - 1)
	return true
}

@(export, link_name = "wjr_Performance_measure")
wjr_Performance_measure :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !perf_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Performance.measure", 1, argc) }
	name: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &name, 0, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	so, em := wj.arg(argc, argv, 1), wj.arg(argc, argv, 2)
	now: f64
	jsb.host(&now, api_decl.Performance_now, wj.wr_Performance_now)
	start: f64
	end := now
	detail := wj.NULL
	ok := true
	if wj.is_object(so) {
		// PerformanceMeasureOptions: {start, end, duration, detail}
		if !wj.is_undefined(em) { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'measure' on 'Performance': endMark cannot be given with options.") }
		s, e, d: wj.JSValue
		if !wj.web_dict_get(ctx, so, "start", &s) { return wj.EXCEPTION }
		if !wj.web_dict_get(ctx, so, "end", &e) { wj.JS_FreeValue(ctx, s); return wj.EXCEPTION }
		if !wj.web_dict_get(ctx, so, "duration", &d) { wj.free_values(ctx, s, e); return wj.EXCEPTION }
		hs, he, hd := !wj.is_undefined(s), !wj.is_undefined(e), !wj.is_undefined(d)
		detail_check: wj.JSValue
		has_detail := wj.web_dict_get(ctx, so, "detail", &detail_check) && !wj.is_undefined(detail_check)
		wj.JS_FreeValue(ctx, detail_check)
		switch {
		case !hs && !he && !hd && !has_detail:   // an empty dictionary: like no options
		case !hs && !he:
			ok = false
			wj.JS_ThrowTypeError(ctx, "Failed to execute 'measure' on 'Performance': start or end is required.")
		case hs && he && hd:
			ok = false
			wj.JS_ThrowTypeError(ctx, "Failed to execute 'measure' on 'Performance': start, end and duration cannot all be given.")
		}
		dur: f64
		if ok && hd && !wj.wj_to_double(ctx, d, &dur, true) { ok = false }
		if ok && he {
			ok = time_of(ctx, e, &end)
		} else if ok && hs && hd {
			s0: f64
			ok = time_of(ctx, s, &s0)
			end = s0 + dur
		}
		if ok && hs {
			ok = time_of(ctx, s, &start)
		} else if ok && he && hd {
			start = end - dur
		}
		wj.free_values(ctx, s, e, d)
		if ok { ok = clone_detail(ctx, so, &detail) }
	} else {
		if !wj.is_undefined(so) { ok = time_of(ctx, so, &start) }
		if ok && !wj.is_undefined(em) { ok = time_of(ctx, em, &end) }
	}
	if !ok { return wj.EXCEPTION }
	if st := jsb.host(&none, api_decl.Performance_measureTimes, wj.wr_Performance_measureTimes, str_view(name), start, end); st != .None {
		wj.JS_FreeValue(ctx, detail)
		return wj.wj_throw_status(ctx, i32(st), "Performance.measure")
	}
	remember_detail(ctx, .Measure, str_view(name), start, detail)
	r := entry_new(ctx, wj.UNDEFINED, .Measure, wj.new_string_len(ctx, str_view(name)), start, end - start, detail)
	if !wj.is_exception(r) { queue_entry(ctx, .Measure, r) }
	return r
}

// The entries matching `name` ("" any) and `type`, as objects.
@(private = "file")
entries :: proc(ctx: ^wj.Context, name: string, type: Kind) -> wj.JSValue {
	arr := wj.JS_NewArray(ctx)
	count: i32
	jsb.host(&count, api_decl.Performance_entryCount, wj.wr_Performance_entryCount, name, type)
	for i in 0 ..< count {
		et: Kind
		if jsb.host(&et, api_decl.Performance_entryType, wj.wr_Performance_entryType, name, type, i) != .None { break }
		start, dur: f64
		jsb.host(&start, api_decl.Performance_entryStartTime, wj.wr_Performance_entryStartTime, name, type, i)
		jsb.host(&dur, api_decl.Performance_entryDuration, wj.wr_Performance_entryDuration, name, type, i)
		entry_name: string
		if jsb.host(&entry_name, api_decl.Performance_entryName, wj.wr_Performance_entryName, name, type, i) != .None { break }
		nm := wj.new_string_len(ctx, entry_name)
		kc, ks := to_text(ctx, nm)
		key := detail_key(ctx, et, ks, start)
		if kc != nil { wj.JS_FreeCString(ctx, kc) }
		detail := wj.JS_Call(ctx, map_get, details, 1, &key)
		wj.JS_FreeValue(ctx, key)
		if wj.is_exception(detail) || wj.is_undefined(detail) {
			if wj.is_exception(detail) { wj.drop_exception(ctx) }
			detail = wj.NULL
		}
		e := entry_new(ctx, wj.UNDEFINED, et, nm, start, dur, detail)
		if wj.is_exception(e) { wj.JS_FreeValue(ctx, arr); return e }
		wj.array_set(ctx, arr, u32(i), e)
	}
	return arr
}

// Stable sort by start time (the arrays are in time order each: entries of several kinds are merged).
@(private = "file")
sort_by_start :: proc "contextless" (ctx: ^wj.Context, arr: wj.JSValue) {
	src := "(a => a.sort((x, y) => x.startTime - y.startTime))"
	sorter := wj.JS_Eval(ctx, raw_data(src), uint(len(src)), "<performance>", wj.EVAL_TYPE_GLOBAL)
	if !wj.is_exception(sorter) {
		a := arr
		r := wj.JS_Call(ctx, sorter, wj.UNDEFINED, 1, &a)
		wj.JS_FreeValue(ctx, r)
	}
	wj.JS_FreeValue(ctx, sorter)
}

// What the timeline buffer holds of `type`: marks and measures from the browser's list, navigation / resource / paint
// entries from its timeline; the slow-event entries are only for observers (as in Chromium).
@(private = "file")
buffered_entries :: proc(ctx: ^wj.Context, type: Kind) -> wj.JSValue {
	// event, first-input, longtask, largest-contentful-paint, layout-shift and element are delivered to observers only
	// (as in Chromium): performance.getEntriesByType returns nothing for them; a PerformanceObserver with buffered: true
	// sees the ones already recorded. visibility-state is likewise observer-only.
	#partial switch type {
	case .Event, .First_Input, .Long_Task, .Largest_Contentful_Paint, .Layout_Shift, .Element, .Visibility_State,
	     .Long_Animation_Frame, .Script:
		return wj.JS_NewArray(ctx)
	}
	if type >= .Navigation { return timeline_entries(ctx, type, 0, nil) }
	return entries(ctx, "", type)
}

// Every entry of the buffer, in start time order.
@(private = "file")
all_entries :: proc(ctx: ^wj.Context) -> wj.JSValue {
	arr := entries(ctx, "", .Any)
	if wj.is_exception(arr) { return arr }
	len_: i64
	wj.JS_GetLength(ctx, arr, &len_)
	for k in Kind.Navigation ..= Kind.Paint {
		more := timeline_entries(ctx, k, 0, nil)
		if wj.is_exception(more) { wj.JS_FreeValue(ctx, arr); return more }
		n: i64
		wj.JS_GetLength(ctx, more, &n)
		for i in 0 ..< n {
			wj.array_set64(ctx, arr, len_, wj.JS_GetPropertyInt64(ctx, more, i))
			len_ += 1
		}
		wj.JS_FreeValue(ctx, more)
	}
	sort_by_start(ctx, arr)
	return arr
}

@(export, link_name = "wjr_Performance_getEntries")
wjr_Performance_getEntries :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !perf_this(ctx, this_val) { return wj.EXCEPTION }
	return all_entries(ctx)
}

@(export, link_name = "wjr_Performance_getEntriesByType")
wjr_Performance_getEntriesByType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !perf_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Performance.getEntriesByType", 1, argc) }
	t: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &t, 0, nil) { return wj.EXCEPTION }
	type, known := kind_of(str_view(t))
	wj.wj_str_free(ctx, &t)
	if !known { return wj.JS_NewArray(ctx) }
	return buffered_entries(ctx, type)
}

@(export, link_name = "wjr_Performance_getEntriesByName")
wjr_Performance_getEntriesByName :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !perf_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Performance.getEntriesByName", 1, argc) }
	n: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &n, 0, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &n)
	type := Kind.Any
	if argc > 1 && !wj.is_undefined(argv[1]) {
		t: wj.Str
		if !wj.wj_to_str(ctx, argv[1], &t, 0, nil) { return wj.EXCEPTION }
		known: bool
		type, known = kind_of(str_view(t))
		wj.wj_str_free(ctx, &t)
		if !known { return wj.JS_NewArray(ctx) }
	}
	// "" means any name for the browser: an empty name matches no entry (names are not empty)
	if n.len == 0 { return wj.JS_NewArray(ctx) }
	if type == .Mark || type == .Measure { return entries(ctx, str_view(n), type) }
	// the buffer (of one kind, or all of them) then the entries with this name
	all := type == .Any ? all_entries(ctx) : buffered_entries(ctx, type)
	if wj.is_exception(all) { return all }
	src := "((a, n) => a.filter((e) => e.name === n))"
	f := wj.JS_Eval(ctx, raw_data(src), uint(len(src)), "<performance>", wj.EVAL_TYPE_GLOBAL)
	args := [2]wj.JSValue{all, wj.new_string_len(ctx, str_view(n))}
	r := wj.is_exception(f) ? f : wj.JS_Call(ctx, f, wj.UNDEFINED, 2, &args[0])
	wj.free_values(ctx, args[0], args[1])
	if !wj.is_exception(f) { wj.JS_FreeValue(ctx, f) }
	return r
}

@(private = "file")
clear_entries :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, type: Kind) -> wj.JSValue {
	if !perf_this(ctx, this_val) { return wj.EXCEPTION }
	n := wj.Str{wj.empty_ptr(), 0, false}
	defer wj.wj_str_free(ctx, &n)
	if argc > 0 && !wj.is_undefined(argv[0]) && !wj.wj_to_str(ctx, argv[0], &n, 0, nil) { return wj.EXCEPTION }
	// their details go with them
	gone := entries(ctx, str_view(n), type)
	count: i64
	wj.JS_GetLength(ctx, gone, &count)
	for i in 0 ..< count {
		e := wj.JS_GetPropertyUint32(ctx, gone, u32(i))
		if pe := (^Entry)(wj.obj_impl(e)); pe != nil {
			kc, ks := to_text(ctx, pe.name)
			key := detail_key(ctx, pe.type, ks, pe.start)
			if kc != nil { wj.JS_FreeCString(ctx, kc) }
			r := wj.JS_Call(ctx, map_delete, details, 1, &key)
			wj.free_values(ctx, r, key)
		}
		wj.JS_FreeValue(ctx, e)
	}
	wj.JS_FreeValue(ctx, gone)
	if type == .Mark {
		jsb.host(&none, api_decl.Performance_clearMarks, wj.wr_Performance_clearMarks, str_view(n))
	} else {
		jsb.host(&none, api_decl.Performance_clearMeasures, wj.wr_Performance_clearMeasures, str_view(n))
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Performance_clearMarks")
wjr_Performance_clearMarks :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return clear_entries(ctx, this_val, argc, argv, .Mark)
}
@(export, link_name = "wjr_Performance_clearMeasures")
wjr_Performance_clearMeasures :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return clear_entries(ctx, this_val, argc, argv, .Measure)
}

// Resource Timing: the browser keeps the resource entries (performance.resource_timing_entries).
@(export, link_name = "wjr_Performance_clearResourceTimings")
wjr_Performance_clearResourceTimings :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if !perf_this(ctx, this_val) { return wj.EXCEPTION }
	jsb.host(&none, api_decl.Performance_clearResourceTimings, wj.wr_Performance_clearResourceTimings)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Performance_setResourceTimingBufferSize")
wjr_Performance_setResourceTimingBufferSize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if !perf_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Performance.setResourceTimingBufferSize", 1, argc) }
	n: u32
	if !wj.wj_to_uint32(ctx, argv[0], &n, 32, 0) { return wj.EXCEPTION }
	jsb.host(&none, api_decl.Performance_setResourceTimingBufferSize, wj.wr_Performance_setResourceTimingBufferSize, n)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Performance_toJSON")
wjr_Performance_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if !perf_this(ctx, this_val) { return wj.EXCEPTION }
	o := wj.JS_NewObject(ctx)
	origin: f64
	jsb.host(&origin, api_decl.Performance_timeOrigin, wj.wr_Performance_timeOrigin)
	wj.JS_SetPropertyStr(ctx, o, "timeOrigin", wj.new_float64(ctx, origin))
	if wj.is_window() {
		t := wjr_Performance_get_timing(ctx, this_val)
		if wj.is_exception(t) { wj.JS_FreeValue(ctx, o); return t }
		j := wjr_PerformanceTiming_toJSON(ctx, t, 0, nil)
		wj.JS_FreeValue(ctx, t)
		if wj.is_exception(j) { wj.JS_FreeValue(ctx, o); return j }
		wj.JS_SetPropertyStr(ctx, o, "timing", j)
	}
	return o
}

// ---- PerformanceObserver ----

// How observe() was first called: entryTypes (multiple) or type (single).
@(private = "file") Observe_Mode :: enum { None, Multiple, Single }

@(private = "file")
Observer :: struct {
	self:      wj.JSValue,   // not counted (the registration below counts)
	callback:  wj.JSValue,
	buffer:    wj.JSValue,   // Array of the entries not delivered yet
	types:     Kinds,        // each type observed
	threshold: f64,          // event timing: the shortest duration it hears of (durationThreshold)
	mode:      Observe_Mode,
	registered: bool,
}

@(private = "file") seen_seq: [Kind]u64          // the timeline entries of each kind the observers have been given up to here
@(private = "file") interest: Kinds              // the kinds of the browser's timeline some observer wants
@(private = "file") listener_set: bool
@(private = "file") registered: [dynamic]wj.JSValue   // counted: the registered observers
@(private = "file") delivery_queued: bool
@(private = "file") supported_types := wj.UNDEFINED   // [SameObject] FrozenArray, made once

@(private = "file")
observer_free :: proc "c" (p: rawptr) {
	o := (^Observer)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, o.callback)
	wj.JS_FreeValueRT(rt, o.buffer)
	wj.libc_free(o)
}

@(private = "file")
observer_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	o := (^Observer)(p)
	wj.wj_mark(rt, o.callback, mark_func)
	wj.wj_mark(rt, o.buffer, mark_func)
}

@(private = "file")
observer_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Observer {
	return (^Observer)(wj.this_impl(ctx, this_val, ifc("PerformanceObserver")))
}

@(private = "file")
observer_impl :: #force_inline proc "contextless" (v: wj.JSValue) -> ^Observer { return (^Observer)(wj.obj_impl(v)) }

@(private = "file")
unregister :: proc(ctx: ^wj.Context, o: ^Observer) {
	if !o.registered { return }
	o.registered = false
	for r, i in registered {
		if !wj.same_ptr(r, o.self) { continue }
		unordered_remove(&registered, i)
		wj.JS_FreeValue(ctx, r)   // may free the observer: last
		update_interest()
		return
	}
}

// What the observers want of the browser's timeline: only those kinds announce new entries to the realm.
@(private = "file")
update_interest :: proc() {
	want: Kinds
	for r in registered { if o := observer_impl(r); o != nil { want += o.types } }
	want &= TIMELINE_KINDS
	// a kind nobody heard of until now starts at its next entry
	for k in Kind.Navigation ..= Kind.Script {
		if k in want && k not_in interest { jsb.host(&seen_seq[k], api_decl.Performance_timelineNextSeq, wj.wr_Performance_timelineNextSeq, k) }
	}
	if want == interest { return }
	interest = want
	if want != {} && !listener_set {
		listener_set = true
		jsb.host(&none, api_decl.Performance_onTimeline, wj.wr_Performance_onTimeline, wj.table_index(rawptr(wj_cb_timeline)), i32(0))
	}
	jsb.host(&none, api_decl.Performance_timelineInterest, wj.wr_Performance_timelineInterest, transmute(u32)want)
}

@(private = "file")
register_observer :: proc(ctx: ^wj.Context, o: ^Observer) -> bool {
	if o.registered { return true }
	if append(&registered, wj.JS_DupValue(ctx, o.self)) != 1 { wj.JS_ThrowOutOfMemory(ctx); return false }
	o.registered = true
	return true
}

@(private = "file")
take_buffer :: proc "contextless" (ctx: ^wj.Context, o: ^Observer) -> wj.JSValue {
	b := o.buffer
	o.buffer = wj.JS_NewArray(ctx)
	return b
}

// PerformanceObserverEntryList: the delivered entries, sorted by start time (as performance.getEntries).
@(private = "file")
list_free :: proc "c" (p: rawptr) {
	wj.JS_FreeValueRT(wj.web_rt(), (^wj.JSValue)(p)^)
	wj.libc_free(p)
}
@(private = "file")
list_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^wj.JSValue)(p)^, mark_func) }

@(private = "file")
entry_list_new :: proc "contextless" (ctx: ^wj.Context, entries: wj.JSValue) -> wj.JSValue {
	impl := (^wj.JSValue)(wj.libc_malloc(size_of(wj.JSValue)))
	if impl == nil { wj.JS_FreeValue(ctx, entries); return wj.JS_ThrowOutOfMemory(ctx) }
	impl^ = entries
	obj := wj.wj_new_object_for(ctx, ifc("PerformanceObserverEntryList"), wj.UNDEFINED, nil, nil)
	if wj.is_exception(obj) { list_free(impl); return obj }
	wj.web_set_impl(obj, impl, list_free, list_mark)
	return obj
}

// The entries of `list` whose name (when given) and type (when given) match, in start time order.
@(private = "file")
filtered :: proc(ctx: ^wj.Context, this_val: wj.JSValue, name: Maybe(string), type: Maybe(Kind)) -> wj.JSValue {
	impl := (^wj.JSValue)(wj.this_impl(ctx, this_val, ifc("PerformanceObserverEntryList")))
	if impl == nil { return wj.EXCEPTION }
	out := wj.JS_NewArray(ctx)
	n: i64
	wj.JS_GetLength(ctx, impl^, &n)
	k: u32
	for i in 0 ..< n {
		e := wj.JS_GetPropertyUint32(ctx, impl^, u32(i))
		pe := (^Entry)(wj.obj_impl(e))
		keep := pe != nil
		if want, ok := type.?; keep && ok { keep = pe.type == want }
		if want, ok := name.?; keep && ok {
			c, s := to_text(ctx, pe.name)
			keep = c != nil && s == want
			if c != nil { wj.JS_FreeCString(ctx, c) }
		}
		if keep { wj.array_set(ctx, out, k, e); k += 1 } else { wj.JS_FreeValue(ctx, e) }
	}
	// stable sort by start time: entries arrive in time order already, except buffered ones before new ones
	sort_by_start(ctx, out)
	return out
}

@(export, link_name = "wjr_PerformanceObserverEntryList_getEntries")
wjr_PerformanceObserverEntryList_getEntries :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return filtered(ctx, this_val, nil, nil)
}

@(export, link_name = "wjr_PerformanceObserverEntryList_getEntriesByType")
wjr_PerformanceObserverEntryList_getEntriesByType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if argc < 1 { return wj.wj_throw_arity(ctx, "PerformanceObserverEntryList.getEntriesByType", 1, argc) }
	t: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &t, 0, nil) { return wj.EXCEPTION }
	type, known := kind_of(str_view(t))
	wj.wj_str_free(ctx, &t)
	if !known { return wj.this_impl(ctx, this_val, ifc("PerformanceObserverEntryList")) != nil ? wj.JS_NewArray(ctx) : wj.EXCEPTION }
	return filtered(ctx, this_val, nil, type)
}

@(export, link_name = "wjr_PerformanceObserverEntryList_getEntriesByName")
wjr_PerformanceObserverEntryList_getEntriesByName :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if argc < 1 { return wj.wj_throw_arity(ctx, "PerformanceObserverEntryList.getEntriesByName", 1, argc) }
	n: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &n, 0, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &n)
	type: Maybe(Kind)
	if argc > 1 && !wj.is_undefined(argv[1]) {
		t: wj.Str
		if !wj.wj_to_str(ctx, argv[1], &t, 0, nil) { return wj.EXCEPTION }
		kind, known := kind_of(str_view(t))
		wj.wj_str_free(ctx, &t)
		if !known { return wj.this_impl(ctx, this_val, ifc("PerformanceObserverEntryList")) != nil ? wj.JS_NewArray(ctx) : wj.EXCEPTION }
		type = kind
	}
	return filtered(ctx, this_val, str_view(n), type)
}

// The PerformanceObserver task: every registered observer with entries gets them, in registration order.
@(private = "file")
deliver :: proc "c" (ctx: ^wj.Context, data: wj.JSValue) {
	context = wj.heap_context()
	delivery_queued = false
	// a callback may observe, disconnect or make new observers: walk a counted copy
	if len(registered) == 0 { return }
	list := make([]wj.JSValue, len(registered), wj.libc_allocator())
	if list == nil { return }
	defer delete(list, wj.libc_allocator())
	for r, i in registered { list[i] = wj.JS_DupValue(ctx, r) }
	for v in list {
		defer wj.JS_FreeValue(ctx, v)
		o := observer_impl(v)
		if o == nil { continue }
		n: i64
		wj.JS_GetLength(ctx, o.buffer, &n)
		if n == 0 { continue }
		entries := entry_list_new(ctx, take_buffer(ctx, o))
		if wj.is_exception(entries) { wj.wj_report_pending(ctx); continue }
		args := [3]wj.JSValue{entries, v, wj.JS_NewObject(ctx)}
		r := wj.JS_Call(ctx, o.callback, v, 3, &args[0])
		if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
		wj.JS_FreeValue(ctx, args[0])
		wj.JS_FreeValue(ctx, args[2])
	}
}

@(private = "file")
queue_delivery :: proc(ctx: ^wj.Context) {
	if delivery_queued { return }
	delivery_queued = wj.web_queue_task(ctx, deliver, wj.UNDEFINED)
}

// A new entry goes to the buffer of each observer of its type.
@(private = "file")
queue_entry :: proc(ctx: ^wj.Context, type: Kind, entry: wj.JSValue) {
	any := false
	for r in registered {
		o := observer_impl(r)
		if o == nil || type not_in o.types { continue }
		if type == .Event {
			if pe := (^Entry)(wj.obj_impl(entry)); pe != nil && pe.duration < o.threshold { continue }
		}
		n: i64
		wj.JS_GetLength(ctx, o.buffer, &n)
		wj.array_set64(ctx, o.buffer, n, wj.JS_DupValue(ctx, entry))
		any = true
	}
	if any { queue_delivery(ctx) }
}

@(export, link_name = "wjr_PerformanceObserver_constructor")
wjr_PerformanceObserver_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor PerformanceObserver requires 'new'") }
	if argc < 1 || !wj.JS_IsFunction(ctx, argv[0]) {
		return wj.JS_ThrowTypeError(ctx, "Failed to construct 'PerformanceObserver': The callback provided as parameter 1 is not a function.")
	}
	o := (^Observer)(wj.libc_calloc(1, size_of(Observer)))
	if o == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	o.callback = wj.JS_DupValue(ctx, argv[0])
	o.buffer = wj.JS_NewArray(ctx)
	o.threshold = 104
	obj := wj.wj_new_object_for(ctx, ifc("PerformanceObserver"), new_target, nil, nil)
	if wj.is_exception(obj) { observer_free(o); return obj }
	o.self = obj
	wj.web_set_impl(obj, o, observer_free, observer_mark)
	return obj
}

@(private = "file")
warn_unsupported :: proc "contextless" (type: string) {
	msg: [160]u8
	k := wj.snprintf(&msg[0], len(msg), "The entry type '%.*s' does not exist or isn't supported.", i32(min(len(type), 60)), raw_data(type))
	wj.wj_console_text(i32(wj.wr_ConsoleLevel.Warn), &msg[0], uint(max(k, 0)))
}

// The entries already in the timeline of `t`, put in the observer's buffer (a "buffered" observe).
@(private = "file")
buffer_old_entries :: proc(ctx: ^wj.Context, o: ^Observer, t: Kind) {
	old := t >= .Navigation ? timeline_entries(ctx, t, 0, nil) : entries(ctx, "", t)
	if wj.is_exception(old) { wj.wj_report_pending(ctx); return }
	n, len_: i64
	wj.JS_GetLength(ctx, old, &n)
	wj.JS_GetLength(ctx, o.buffer, &len_)
	for i in 0 ..< n {
		e := wj.JS_GetPropertyInt64(ctx, old, i)
		if pe := (^Entry)(wj.obj_impl(e)); t == .Event && pe != nil && pe.duration < o.threshold { wj.JS_FreeValue(ctx, e); continue }
		wj.array_set64(ctx, o.buffer, len_, e)
		len_ += 1
	}
	wj.JS_FreeValue(ctx, old)
	if len_ > 0 { queue_delivery(ctx) }
}

// observe(options) (Performance Timeline 3.3.1)
@(export, link_name = "wjr_PerformanceObserver_observe")
wjr_PerformanceObserver_observe :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	o := observer_this(ctx, this_val)
	if o == nil { return wj.EXCEPTION }
	opt := wj.arg(argc, argv, 0)
	if !wj.web_dict_check(ctx, opt, "PerformanceObserverInit") { return wj.EXCEPTION }
	entry_types, type, buffered, dthreshold: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "entryTypes", &entry_types) { return wj.EXCEPTION }
	if !wj.web_dict_get(ctx, opt, "type", &type) { wj.JS_FreeValue(ctx, entry_types); return wj.EXCEPTION }
	if !wj.web_dict_get(ctx, opt, "buffered", &buffered) { wj.free_values(ctx, entry_types, type); return wj.EXCEPTION }
	if !wj.web_dict_get(ctx, opt, "durationThreshold", &dthreshold) { wj.free_values(ctx, entry_types, type, buffered); return wj.EXCEPTION }
	has_types, has_type := !wj.is_undefined(entry_types), !wj.is_undefined(type)
	want_buffered := wj.JS_ToBool(ctx, buffered) != 0
	result := wj.UNDEFINED
	threshold := o.threshold
	if !wj.is_undefined(dthreshold) {
		// durationThreshold: the events it hears of last at least this long, 16 ms or more
		if !wj.wj_to_double(ctx, dthreshold, &threshold, true) { result = wj.EXCEPTION } else { threshold = max(threshold, 16) }
	}
	switch {
	case wj.is_exception(result):   // (the exception is pending)
	case !has_types && !has_type:
		result = wj.JS_ThrowTypeError(ctx, "Failed to execute 'observe' on 'PerformanceObserver': An observe() call must include either entryTypes or type arguments.")
	case has_types && (has_type || !wj.is_undefined(buffered)):
		result = wj.JS_ThrowTypeError(ctx, "Failed to execute 'observe' on 'PerformanceObserver': An observe() call must not include both entryTypes and type arguments.")
	case (o.mode == .Multiple && has_type) || (o.mode == .Single && has_types):
		result = wj.wj_throw_dom(ctx, "InvalidModificationError", "Failed to execute 'observe' on 'PerformanceObserver': This observer has already been called with a different argument.")
	case has_types:
		// entryTypes: replaces what is observed
		n: i64
		types: Kinds
		if !wj.is_object(entry_types) || wj.JS_GetLength(ctx, entry_types, &n) < 0 {
			if !wj.is_exception(result) { result = wj.JS_ThrowTypeError(ctx, "Failed to execute 'observe' on 'PerformanceObserver': entryTypes is not a sequence.") }
		} else {
			for i in 0 ..< n {
				v := wj.JS_GetPropertyInt64(ctx, entry_types, i)
				s: wj.Str
				if !wj.wj_to_str(ctx, v, &s, 0, nil) { result = wj.EXCEPTION; wj.JS_FreeValue(ctx, v); break }
				if t, known := kind_of(str_view(s)); known { types += {t} } else { warn_unsupported(str_view(s)) }
				wj.wj_str_free(ctx, &s)
				wj.JS_FreeValue(ctx, v)
			}
			if !wj.is_exception(result) && types != {} {
				o.mode = .Multiple
				o.types = types
				if !register_observer(ctx, o) { result = wj.EXCEPTION } else { update_interest() }
			}
		}
	case:
		s: wj.Str
		if !wj.wj_to_str(ctx, type, &s, 0, nil) {
			result = wj.EXCEPTION
		} else {
			if t, known := kind_of(str_view(s)); !known {
				warn_unsupported(str_view(s))
			} else {
				o.mode = .Single
				o.types += {t}
				if t == .Event { o.threshold = threshold }
				if !register_observer(ctx, o) {
					result = wj.EXCEPTION
				} else {
					update_interest()
					if want_buffered { buffer_old_entries(ctx, o, t) }
				}
			}
			wj.wj_str_free(ctx, &s)
		}
	}
	if !wj.is_exception(result) && has_types && !wj.is_undefined(dthreshold) { o.threshold = threshold }
	wj.free_values(ctx, entry_types, type, buffered, dthreshold)
	return result
}

@(export, link_name = "wjr_PerformanceObserver_disconnect")
wjr_PerformanceObserver_disconnect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := observer_this(ctx, this_val)
	if o == nil { return wj.EXCEPTION }
	wj.JS_FreeValue(ctx, take_buffer(ctx, o))
	o.types = {}
	o.mode = .None
	unregister(ctx, o)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_PerformanceObserver_takeRecords")
wjr_PerformanceObserver_takeRecords :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	o := observer_this(ctx, this_val)
	return o != nil ? take_buffer(ctx, o) : wj.EXCEPTION
}

@(export, link_name = "wjr_PerformanceObserver_static_get_supportedEntryTypes")
wjr_PerformanceObserver_static_get_supportedEntryTypes :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(supported_types) {
		src := "Object.freeze(['element', 'event', 'first-input', 'largest-contentful-paint', 'layout-shift', 'long-animation-frame', 'longtask', 'mark', 'measure', 'navigation', 'paint', 'resource', 'visibility-state'])"
		v := wj.JS_Eval(ctx, raw_data(src), uint(len(src)), "<performance>", wj.EVAL_TYPE_GLOBAL)
		if wj.is_exception(v) { return v }
		supported_types = v
	}
	return wj.JS_DupValue(ctx, supported_types)
}

// The browser announces new timeline entries of the kinds the observers asked for: each goes to the observers of its
// kind, and one task delivers them (a callback of the browser: a task of the page, then the microtask checkpoint).
@(export, link_name = "wj_cb_timeline")
wj_cb_timeline :: proc "c" (user: i32, kinds: i32) {
	context = wj.heap_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	announced := transmute(Kinds)u32(kinds)
	for k in Kind.Navigation ..= Kind.Script {
		if k not_in announced || k not_in interest { continue }
		next := seen_seq[k]
		list := timeline_entries(ctx, k, seen_seq[k], &next)
		if wj.is_exception(list) { wj.wj_report_pending(ctx); continue }
		seen_seq[k] = next
		n: i64
		wj.JS_GetLength(ctx, list, &n)
		for i in 0 ..< n {
			e := wj.JS_GetPropertyInt64(ctx, list, i)
			queue_entry(ctx, k, e)
			wj.JS_FreeValue(ctx, e)
		}
		wj.JS_FreeValue(ctx, list)
	}
}
