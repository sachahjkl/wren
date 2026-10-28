// web_navtiming.odin: the legacy performance.navigation (PerformanceNavigation). performance.timing
// (PerformanceTiming) is in web_perf. A plain navigation, no redirect, is what this one reports. The object is made by
// the engine and kept by the Performance object ([SameObject]). Ported from native/js/runtime/web_navtiming.c.
package odin_glue

import "../odin/wj"

@(private = "file") iface_perf := i32(-2)
@(private = "file") iface_navigation := i32(-2)

@(private = "file")
perf_iface :: proc "c" () -> i32 {
	if iface_perf == -2 { iface_perf = wj.iface("Performance") }
	return iface_perf
}
@(private = "file")
navigation_iface :: proc "c" () -> i32 {
	if iface_navigation == -2 { iface_navigation = wj.iface("PerformanceNavigation") }
	return iface_navigation
}

// the object of `this` Performance, made on first use and kept by it ([SameObject])
@(private = "file")
kept :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, key: cstring, make: proc "c" (ctx: ^wj.Context) -> wj.JSValue) -> wj.JSValue {
	v := wj.web_extra_get(ctx, this_val, key)
	if wj.is_object(v) { return v }
	wj.JS_FreeValue(ctx, v)
	o := make(ctx)
	if wj.is_exception(o) { return o }
	wj.web_extra_set(ctx, this_val, key, wj.JS_DupValue(ctx, o))
	return o
}

// performance.navigation: a plain navigation, no redirect
@(private = "file")
make_navigation :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	return wj.wj_new_object(ctx, navigation_iface(), nil, nil)
}

@(export, link_name = "wjr_Performance_get_navigation")
wjr_Performance_get_navigation :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, perf_iface()) == nil { return wj.EXCEPTION }
	return kept(ctx, this_val, "navigation", make_navigation)
}

@(export, link_name = "wjr_PerformanceNavigation_get_type")
wjr_PerformanceNavigation_get_type :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.wj_this(ctx, this_val, navigation_iface()) != nil ? wj.new_int32(0) : wj.EXCEPTION
}

@(export, link_name = "wjr_PerformanceNavigation_get_redirectCount")
wjr_PerformanceNavigation_get_redirectCount :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.wj_this(ctx, this_val, navigation_iface()) != nil ? wj.new_int32(0) : wj.EXCEPTION
}
