// web_scheduler.odin: the Prioritized Task Scheduling API (scheduler.postTask / scheduler.yield, TaskController,
// TaskSignal, TaskPriorityChangeEvent, navigator.scheduling.isInputPending). The priority queue and the ordering are
// native (src/page/bindings_scheduler.odin, on the page's event loop); this glue holds each task's promise, callback and
// signal, and runs the callback when the browser says the task is due, resolving the promise with the callback's return
// value (or rejecting it with an abort reason). Ported from native/js/runtime/web_scheduler.c; same wjr_* symbols and
// export (wj_cb_scheduler).
//
// A task is a record of a generational pool (the browser calls back with a user word: 16 bits of slot, 16 of
// generation). Abort goes through the AbortSignal: when the task's signal aborts before the task runs, the record is
// cancelled (Scheduler_cancel) and the promise rejected with the signal's reason. TaskController extends
// AbortController and TaskSignal extends AbortSignal; the priority lives on the signal's hidden state, and setPriority
// fires a TaskPriorityChangeEvent.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") if_scheduler, if_task_controller, if_task_signal, if_priority_event, if_scheduling := i32(-2), i32(-2), i32(-2), i32(-2), i32(-2)
@(private = "file") nothing: abi.Nothing

@(private = "file") TaskPriority :: api_decl.TaskPriority

@(private = "file")
Task :: struct {
	used:     bool,
	gen:      u32,
	id:       u64,            // the browser's task id
	callback: wj.JSValue,     // the task's callback, undefined for a yield continuation (counted)
	resolve:  wj.JSValue,
	reject:   wj.JSValue,
	signal:   wj.JSValue,     // the AbortSignal watched, or undefined (counted)
	priority: TaskPriority,   // its effective priority (what a yield() inside it inherits)
}

@(private = "file") tasks: [dynamic]Task
@(private = "file") free_slots: [dynamic]u32

// The task whose callback runs (what a scheduler.yield() inside it inherits): its signal (borrowed) and priority.
@(private = "file")
Current :: struct { signal: wj.JSValue, priority: TaskPriority, has: bool }
@(private = "file") current := Current{signal = wj.UNDEFINED}

@(private = "file")
task_alloc :: proc() -> (u32, bool) {
	if n := len(free_slots); n > 0 {
		slot := free_slots[n - 1]
		pop(&free_slots)
		return slot, true
	}
	if len(tasks) > 0xFFFF { return 0, false }   // the user word has 16 bits of slot
	if _, err := append(&tasks, Task{}); err != nil { return 0, false }
	return u32(len(tasks) - 1), true
}

@(private = "file")
task_release :: proc(ctx: ^wj.Context, slot: u32) {
	t := &tasks[slot]
	if !t.used { return }
	vals := [4]wj.JSValue{t.callback, t.resolve, t.reject, t.signal}
	t^ = Task{gen = t.gen + 1}
	append(&free_slots, slot)
	for v in vals { wj.JS_FreeValue(ctx, v) }
}

@(private = "file")
task_user :: #force_inline proc "contextless" (slot: u32) -> i32 { return i32((tasks[slot].gen & 0xFFFF) << 16 | (slot & 0xFFFF)) }

@(private = "file")
task_from_user :: proc "contextless" (user: i64) -> (u32, bool) {
	slot := u32(u64(user) & 0xFFFF)
	gen := u32((u64(user) >> 16) & 0xFFFF)
	if int(slot) >= len(tasks) || !tasks[slot].used || (tasks[slot].gen & 0xFFFF) != gen { return 0, false }
	return slot, true
}

// ---- priority values ----

@(private = "file")
priority_of :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> TaskPriority {
	c, s := to_text(ctx, v)
	if c == nil { return .User_Visible }
	defer wj.free_cstring(ctx, c)
	switch s {
	case "user-blocking": return .User_Blocking
	case "background":    return .Background
	}
	return .User_Visible
}

@(private = "file")
priority_name :: proc "contextless" (p: TaskPriority) -> cstring {
	switch p {
	case .User_Blocking: return "user-blocking"
	case .Background:    return "background"
	case .User_Visible:
	}
	return "user-visible"
}

// The priority a TaskSignal carries (hidden state "taskPriority"), or user-visible.
@(private = "file")
signal_priority :: proc "contextless" (ctx: ^wj.Context, signal: wj.JSValue) -> TaskPriority {
	if !wj.is_object(signal) { return .User_Visible }
	v := wj.web_extra_get(ctx, signal, "taskPriority")
	defer wj.JS_FreeValue(ctx, v)
	if !wj.is_number(v) { return .User_Visible }
	n: i32
	wj.JS_ToInt32(ctx, &n, v)
	return n >= i32(min(TaskPriority)) && n <= i32(max(TaskPriority)) ? TaskPriority(n) : .User_Visible
}

@(private = "file")
set_signal_priority :: proc "contextless" (ctx: ^wj.Context, signal: wj.JSValue, p: TaskPriority) {
	wj.web_extra_set(ctx, signal, "taskPriority", wj.new_int32(i32(p)))
}

// ---- the scheduler (a singleton kept on the global's hidden state) ----

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_get_scheduler")
wjr_WindowOrWorkerGlobalScope_get_scheduler :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	g := wj.realm_global()
	s := wj.web_extra_get(ctx, g, "scheduler")
	if wj.is_object(s) { return s }
	wj.JS_FreeValue(ctx, s)
	made := wj.wj_new_object(ctx, iface_lazy(&if_scheduler, "Scheduler"), nil, nil)
	if wj.is_object(made) { wj.web_extra_set(ctx, g, "scheduler", wj.JS_DupValue(ctx, made)) }
	return made
}

// Settle a task's promise (and let its record go); `v` is consumed.
@(private = "file")
task_settle :: proc(ctx: ^wj.Context, slot: u32, reject: bool, v: wj.JSValue) {
	f := wj.JS_DupValue(ctx, reject ? tasks[slot].reject : tasks[slot].resolve)
	task_release(ctx, slot)
	wj.web_settle(ctx, f, v)
	wj.JS_FreeValue(ctx, f)
}

// The abort reaction on the signal: reject the task's promise and cancel the browser's task. func_data: [user].
@(private = "file")
abort_reaction :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, func_data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	user: i64
	wj.JS_ToInt64(ctx, &user, func_data[0])
	slot, ok := task_from_user(user)
	if !ok { return wj.UNDEFINED }
	jsb.host(&nothing, api_decl.Scheduler_cancel, wj.wr_Scheduler_cancel, tasks[slot].id)
	signal := tasks[slot].signal
	reason := wj.is_object(signal) ? web_signal_reason(ctx, signal) : wj.web_dom_exception(ctx, "AbortError", "task aborted")
	task_settle(ctx, slot, true, reason)
	return wj.UNDEFINED
}

// A new task record posted to the browser (its callback, signal and priority given; the promise returned).
@(private = "file")
post :: proc(ctx: ^wj.Context, callback: wj.JSValue, signal: wj.JSValue, priority: TaskPriority, delay: f64) -> wj.JSValue {
	funcs: [2]wj.JSValue
	p := wj.web_promise_new(ctx, &funcs[0])
	if wj.is_exception(p) { return p }
	slot, ok := task_alloc()
	if !ok { free_values(ctx, funcs[0], funcs[1], p); return wj.JS_ThrowOutOfMemory(ctx) }
	tasks[slot] = Task{
		used = true, gen = tasks[slot].gen,
		callback = wj.JS_DupValue(ctx, callback),
		resolve = funcs[0], reject = funcs[1],
		signal = wj.is_object(signal) ? wj.JS_DupValue(ctx, signal) : wj.UNDEFINED,
		priority = priority,
	}
	user := task_user(slot)
	id: u64
	jsb.host(&id, api_decl.Scheduler_post, wj.wr_Scheduler_post, u32(wj.table_index(rawptr(wj_cb_scheduler))), user, priority, delay)
	tasks[slot].id = id
	// the abort wired: signal.addEventListener('abort', reaction) with the record's user bound
	if wj.is_object(signal) {
		data := wj.new_int64(ctx, i64(user))
		reaction := wj.JS_NewCFunctionData(ctx, abort_reaction, 0, 0, 1, &data)
		add_listener(ctx, signal, "abort", reaction)
		wj.JS_FreeValue(ctx, reaction)
	}
	return p
}

// SchedulerPostTaskOptions {signal, priority, delay}; the signal counted.
@(private = "file")
Post_Options :: struct { signal: wj.JSValue, priority: TaskPriority, has_priority: bool, delay: f64 }

@(private = "file")
post_options :: proc "contextless" (ctx: ^wj.Context, opts: wj.JSValue, o: ^Post_Options) -> bool {
	o^ = {signal = wj.UNDEFINED, priority = .User_Visible}
	if !wj.is_object(opts) { return true }
	if !wj.web_dict_get(ctx, opts, "signal", &o.signal) { return false }
	pr, d: wj.JSValue
	if !wj.web_dict_get(ctx, opts, "priority", &pr) { return false }
	if wj.is_string(pr) { o.priority = priority_of(ctx, pr); o.has_priority = true }
	wj.JS_FreeValue(ctx, pr)
	if !wj.web_dict_get(ctx, opts, "delay", &d) { return false }
	if !wj.is_undefined(d) {
		dv: f64
		wj.JS_ToFloat64(ctx, &dv, d)
		if dv > 0 { o.delay = dv }
	}
	wj.JS_FreeValue(ctx, d)
	return true
}

@(export, link_name = "wjr_Scheduler_postTask")
wjr_Scheduler_postTask :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if wj.wj_this(ctx, this_val, iface_lazy(&if_scheduler, "Scheduler")) == nil { return wj.EXCEPTION }
	if argc < 1 || !wj.JS_IsFunction(ctx, argv[0]) {
		return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Failed to execute 'postTask': the callback is not a function"))
	}
	o: Post_Options
	ok := post_options(ctx, wj.arg(argc, argv, 1), &o)
	defer wj.JS_FreeValue(ctx, o.signal)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	// the explicit option wins, then the priority of a TaskSignal, then user-visible
	if !o.has_priority && wj.is_object(o.signal) { o.priority = signal_priority(ctx, o.signal) }
	if wj.is_object(o.signal) && web_signal_aborted(o.signal) { return wj.web_promise_rejected(ctx, web_signal_reason(ctx, o.signal)) }
	return post(ctx, argv[0], o.signal, o.priority, o.delay)
}

// scheduler.yield(): a continuation posted at the current task's priority, watching its signal (user-visible with no
// signal outside a scheduler task); its promise resolves with undefined when it runs.
@(export, link_name = "wjr_Scheduler_yield")
wjr_Scheduler_yield :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if wj.wj_this(ctx, this_val, iface_lazy(&if_scheduler, "Scheduler")) == nil { return wj.EXCEPTION }
	signal := current.has ? current.signal : wj.UNDEFINED
	priority := current.has ? current.priority : TaskPriority.User_Visible
	if wj.is_object(signal) && web_signal_aborted(signal) { return wj.web_promise_rejected(ctx, web_signal_reason(ctx, signal)) }
	return post(ctx, wj.UNDEFINED, signal, priority, 0)
}

// The browser says the task is due: its callback runs and the promise resolves with what it returns (a throw rejects);
// a yield continuation resolves with undefined.
@(export, link_name = "wj_cb_scheduler")
wj_cb_scheduler :: proc "c" (user: i32) {
	context = m4_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	slot, ok := task_from_user(i64(user))
	if !ok { return }
	t := tasks[slot]
	callback := wj.JS_DupValue(ctx, t.callback)
	resolve, reject := wj.JS_DupValue(ctx, t.resolve), wj.JS_DupValue(ctx, t.reject)
	signal := wj.JS_DupValue(ctx, t.signal)
	defer free_values(ctx, callback, resolve, reject)
	task_release(ctx, slot)

	// this task is the current one while its callback runs (a synchronous yield() inherits its signal and priority);
	// the previous state comes back after (tasks nest through microtasks)
	prev := current
	current = Current{signal, t.priority, true}
	result := wj.JS_IsFunction(ctx, callback) ? wj.JS_Call(ctx, callback, wj.UNDEFINED, 0, nil) : wj.UNDEFINED
	current = prev
	wj.JS_FreeValue(ctx, signal)
	if wj.is_exception(result) {
		wj.web_settle(ctx, reject, wj.JS_GetException(ctx))
	} else {
		wj.web_settle(ctx, resolve, result)
	}
}

// ---- TaskController / TaskSignal / TaskPriorityChangeEvent ----

// new TaskController({priority}): an AbortController whose signal is a TaskSignal carrying the priority.
@(export, link_name = "wjr_TaskController_constructor")
wjr_TaskController_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor TaskController requires 'new'") }
	priority := TaskPriority.User_Visible
	if init := wj.arg(argc, argv, 0); wj.is_object(init) {
		pr: wj.JSValue
		if !wj.web_dict_get(ctx, init, "priority", &pr) { return wj.EXCEPTION }
		if wj.is_string(pr) { priority = priority_of(ctx, pr) }
		wj.JS_FreeValue(ctx, pr)
	}
	ctrl := web_controller_construct(ctx, new_target, iface_lazy(&if_task_controller, "TaskController"), iface_lazy(&if_task_signal, "TaskSignal"))
	if wj.is_exception(ctrl) { return ctrl }
	signal := wj.JS_GetPropertyStr(ctx, ctrl, "signal")
	if wj.is_object(signal) { set_signal_priority(ctx, signal, priority) }
	wj.JS_FreeValue(ctx, signal)
	return ctrl
}

@(export, link_name = "wjr_TaskController_setPriority")
wjr_TaskController_setPriority :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if argc < 1 || !wj.is_string(argv[0]) { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'setPriority': a priority is required") }
	priority := priority_of(ctx, argv[0])
	signal := wj.JS_GetPropertyStr(ctx, this_val, "signal")
	defer wj.JS_FreeValue(ctx, signal)
	if !wj.is_object(signal) { return wj.UNDEFINED }
	// "is priority changing": setPriority must not run re-entrantly from a prioritychange handler
	flag := wj.web_extra_get(ctx, signal, "priorityChanging")
	changing := wj.JS_ToBool(ctx, flag) > 0
	wj.JS_FreeValue(ctx, flag)
	if changing { return wj.JS_Throw(ctx, wj.web_dom_exception(ctx, "NotAllowedError", "setPriority called recursively")) }
	prev := signal_priority(ctx, signal)
	if prev == priority { return wj.UNDEFINED }
	set_signal_priority(ctx, signal, priority)
	// the queued tasks bound to this signal move in the browser's queue
	for t in tasks {
		if t.used && wj.same_ptr(t.signal, signal) { jsb.host(&nothing, api_decl.Scheduler_setPriority, wj.wr_Scheduler_setPriority, t.id, priority) }
	}
	wj.web_extra_set(ctx, signal, "priorityChanging", wj.TRUE)
	// a TaskPriorityChangeEvent('prioritychange', {previousPriority}) at the signal
	ev := wj.web_event_new(ctx, iface_lazy(&if_priority_event, "TaskPriorityChangeEvent"), "prioritychange", false, false)
	if wj.is_object(ev) {
		wj.web_extra_set(ctx, ev, "previousPriority", wj.new_string(ctx, priority_name(prev)))
		wj.web_event_fire(ctx, signal, ev)
		wj.JS_FreeValue(ctx, ev)
	}
	wj.web_extra_set(ctx, signal, "priorityChanging", wj.FALSE)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_TaskSignal_get_priority")
wjr_TaskSignal_get_priority :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.new_string(ctx, priority_name(signal_priority(ctx, this_val)))
}

// TaskSignal.any(signals, {priority}): a composite TaskSignal that aborts when any source aborts. Its priority is fixed:
// init.priority's TaskPriority, or the current priority of the TaskSignal given as init.priority.
@(export, link_name = "wjr_TaskSignal_static_any")
wjr_TaskSignal_static_any :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "TaskSignal.any", 1, argc) }
	priority := TaskPriority.User_Visible
	if init := wj.arg(argc, argv, 1); wj.is_object(init) {
		pr: wj.JSValue
		if !wj.web_dict_get(ctx, init, "priority", &pr) { return wj.EXCEPTION }
		if wj.is_string(pr) { priority = priority_of(ctx, pr) } else if wj.is_object(pr) { priority = signal_priority(ctx, pr) }
		wj.JS_FreeValue(ctx, pr)
	}
	obj := web_signal_any(ctx, argv[0], iface_lazy(&if_task_signal, "TaskSignal"), "TaskSignal.any")
	if wj.is_object(obj) { set_signal_priority(ctx, obj, priority) }
	return obj
}

@(export, link_name = "wjr_TaskPriorityChangeEvent_get_previousPriority")
wjr_TaskPriorityChangeEvent_get_previousPriority :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	v := wj.web_extra_get(ctx, this_val, "previousPriority")
	if wj.is_string(v) { return v }
	wj.JS_FreeValue(ctx, v)
	return wj.new_string(ctx, "user-visible")
}

@(export, link_name = "wjr_TaskPriorityChangeEvent_constructor")
wjr_TaskPriorityChangeEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj_event_construct(ctx, new_target, argc, argv, iface_lazy(&if_priority_event, "TaskPriorityChangeEvent"), "TaskPriorityChangeEvent")
	if wj.is_exception(ev) { return ev }
	// the init dictionary's required previousPriority
	if init := wj.arg(argc, argv, 1); wj.is_object(init) {
		pr := wj.JS_GetPropertyStr(ctx, init, "previousPriority")
		if wj.is_string(pr) { wj.web_extra_set(ctx, ev, "previousPriority", wj.JS_DupValue(ctx, pr)) }
		wj.JS_FreeValue(ctx, pr)
	}
	return ev
}

// ---- navigator.scheduling.isInputPending ----

@(export, link_name = "wjr_Navigator_get_scheduling")
wjr_Navigator_get_scheduling :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	g := wj.realm_global()
	s := wj.web_extra_get(ctx, g, "scheduling")
	if wj.is_object(s) { return s }
	wj.JS_FreeValue(ctx, s)
	made := wj.wj_new_object(ctx, iface_lazy(&if_scheduling, "Scheduling"), nil, nil)
	if wj.is_object(made) { wj.web_extra_set(ctx, g, "scheduling", wj.JS_DupValue(ctx, made)) }
	return made
}

@(export, link_name = "wjr_Scheduling_isInputPending")
wjr_Scheduling_isInputPending :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if wj.wj_this(ctx, this_val, iface_lazy(&if_scheduling, "Scheduling")) == nil { return wj.EXCEPTION }
	include_continuous := false
	if opts := wj.arg(argc, argv, 0); wj.is_object(opts) {
		ic: wj.JSValue
		if !wj.web_dict_get(ctx, opts, "includeContinuous", &ic) { return wj.EXCEPTION }
		include_continuous = wj.JS_ToBool(ctx, ic) > 0
		wj.JS_FreeValue(ctx, ic)
	}
	pending: bool
	jsb.host(&pending, api_decl.Scheduler_isInputPending, wj.wr_Scheduler_isInputPending, include_continuous)
	return wj.new_bool(pending)
}
