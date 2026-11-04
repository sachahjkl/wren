package wasm

// The builds with Tracy (package trace): each call of a module into the browser (an import: a DOM call, a style or layout
// read, a timer...) is a zone named after it, "module.name". Its callback goes through one that begins and ends the zone;
// without Tracy the import keeps its own.

@(require) import "core:fmt"   // (these two: Tracy)
@(require) import "wb:base"
import "wb:trace"

when trace.TRACY {

@(private = "file")
Traced :: struct {
	site: trace.Site,
	fn:   Host_Fn,
	env:  rawptr,
}

@(private)
host_trace_wrap :: proc(im: ^Import, fn: Host_Fn, env: rawptr) -> (Host_Fn, rawptr) {
	t := new(Traced, base.permanent_allocator())   // (Tracy keeps the site's address)
	trace.site_init(&t.site, fmt.tprintf("%s.%s", im.module, im.name), base.permanent_allocator())
	t.fn, t.env = fn, env
	return host_traced, t
}

@(private = "file")
host_traced :: proc "c" (env: rawptr, caller: wt_caller, args: [^]wt_val_raw, n: uint) -> wt_trap {
	t := (^Traced)(env)
	trace.begin(&t.site)
	r := t.fn(t.env, caller, args, n)
	trace.end(&t.site)
	return r
}

} else {

@(private)
host_trace_wrap :: #force_inline proc(im: ^Import, fn: Host_Fn, env: rawptr) -> (Host_Fn, rawptr) { return fn, env }

}
