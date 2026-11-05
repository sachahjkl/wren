package jsrt

// Classes registered by the host (the C API's JS_NewClass): objects with an opaque pointer, a
// finalizer, optional exposure of the references the opaque data holds, and optional exotic
// behavior for the properties they do not store. Wren's glue builds its platform objects on this.
//
// Collector cooperation. A finalizer runs for every dead host object *before* any cell of that
// collection is freed (gc_collect), so it may still touch the cells its object referenced (drop
// host references, read their opaque data). gc_mark exposes the cells the opaque data references;
// the collector uses it twice, once to subtract those references from the host counts (so a cycle
// through opaque data does not keep itself alive) and once to trace them when the owner is live.

FIRST_HOST_CLASS :: 64

Host_Object :: struct {
	class_id:  u32,
	opaque:    rawptr,
	hook_idx:  int, // index in Runtime.gc_hooked, -1 when not listed
	payload:   u32, // bytes of opaque data in the same block, from HOST_PAYLOAD_OFFSET (0: the host's own pointer, if any)
}

// Where a host object's own opaque data starts in its block (8-aligned: it holds 64-bit values).
HOST_PAYLOAD_OFFSET :: (size_of(Host_Object) + 7) &~ 7

// A pass over the references of the hooked objects: counting (subtracting from the host counts of the cells in
// Runtime.ext_cells, which gc_mark_ext puts back after) when `counting`, marking otherwise.
Host_Mark_State :: struct {
	rt:       ^Runtime,
	counting: bool,
}

Host_Exotic :: struct {
	get_own_property: proc(ctx: ^Context, o: ^Object, a: Atom, d: ^Prop_Desc) -> int, // d may be nil; 1 found, 0 absent, -1 exception
	own_keys:         proc(ctx: ^Context, o: ^Object, out: ^[dynamic]Atom, filter: Keys_Filters) -> bool,
	delete_property:  proc(ctx: ^Context, o: ^Object, a: Atom) -> int,
	define_own:       proc(ctx: ^Context, o: ^Object, a: Atom, d: ^Prop_Desc, throw_flag: bool) -> int,
	has_property:     proc(ctx: ^Context, o: ^Object, a: Atom) -> int,
	get_property:     proc(ctx: ^Context, o: ^Object, a: Atom, receiver: Value) -> Value,
	set_property:     proc(ctx: ^Context, o: ^Object, a: Atom, v: Value, receiver: Value, throw_flag: bool) -> int,
}

Class_Hooks :: struct {
	name:      string,
	finalizer: proc(rt: ^Runtime, o: ^Object),
	gc_mark:   proc(rt: ^Runtime, o: ^Object, st: ^Host_Mark_State),
	exotic:    ^Host_Exotic,
	user:      rawptr, // the registrant's data (the C API keeps its JSClassDef here)
	defined:   bool,
}

// A fresh class id (the C API's JS_NewClassID).
host_class_new_id :: proc(rt: ^Runtime) -> u32 {
	append(&rt.host_classes, Class_Hooks{})
	return u32(FIRST_HOST_CLASS + len(rt.host_classes) - 1)
}

host_class_define :: proc(rt: ^Runtime, id: u32, hooks: Class_Hooks) -> bool {
	i := int(id) - FIRST_HOST_CLASS
	if i < 0 || i >= len(rt.host_classes) {return false}
	rt.host_classes[i] = hooks
	rt.host_classes[i].defined = true
	return true
}

host_class :: #force_inline proc "contextless" (rt: ^Runtime, id: u32) -> ^Class_Hooks {
	i := int(id) - FIRST_HOST_CLASS
	if i < 0 || i >= len(rt.host_classes) {return nil}
	return &rt.host_classes[i]
}

host_object_of :: #force_inline proc "contextless" (o: ^Object) -> ^Host_Object {
	if o == nil || o.class != .host {return nil}
	d, _ := o.data.(^Host_Object)
	return d
}

host_exotic_of :: proc "contextless" (rt: ^Runtime, o: ^Object) -> ^Host_Exotic {
	d := host_object_of(o)
	if d == nil {return nil}
	c := host_class(rt, d.class_id)
	return c != nil ? c.exotic : nil
}

// An object of host class `id` with prototype `proto` (may be nil), and `payload` zeroed bytes of opaque data in the
// block of its Host_Object (its opaque pointer), freed with it. `marked`: listed for the class's gc_mark at once
// (host_object_set_marked).
host_object_new :: proc(ctx: ^Context, proto: ^Object, id: u32, payload := 0, marked := true) -> ^Object {
	rt := ctx.rt
	o := object_new_proto(ctx, proto, .host)
	d := cast(^Host_Object)mem_alloc(rt, HOST_PAYLOAD_OFFSET + payload)
	d.class_id = id
	d.hook_idx = -1
	d.payload = u32(payload)
	if payload > 0 {d.opaque = rawptr(uintptr(d) + HOST_PAYLOAD_OFFSET)}
	o.data = d
	c := host_class(rt, id)
	o.host_exotic = c == nil || !c.defined || c.exotic != nil
	if c != nil {
		if c.gc_mark != nil && marked {
			d.hook_idx = len(rt.gc_hooked)
			list_push(&rt.gc_hooked, o)
		}
		if c.finalizer != nil {list_push(&rt.host_finals, o)}
	}
	return o
}

// Whether the collector asks the class's gc_mark about `o` (listed in Runtime.gc_hooked). An object of such a class that
// is not listed holds no value of its own data, as far as the collector knows (a wrapper with nothing of its own: the
// collection's counting pass skips it); its host lists it before the data takes one. One it forgot keeps the values
// its data counts (host references) as roots, their counts not subtracted: a leak, not a value freed too early.
host_object_set_marked :: proc(rt: ^Runtime, o: ^Object, marked: bool) {
	d := host_object_of(o)
	if d == nil || (d.hook_idx >= 0) == marked {return}
	if c := host_class(rt, d.class_id); c == nil || c.gc_mark == nil {return}
	if marked {
		d.hook_idx = len(rt.gc_hooked)
		list_push(&rt.gc_hooked, o)
	} else {
		hooked_remove(rt, d)
	}
}

@(private = "file")
hooked_remove :: proc(rt: ^Runtime, d: ^Host_Object) {
	last := len(rt.gc_hooked) - 1
	if d.hook_idx != last {
		moved := rt.gc_hooked[last]
		rt.gc_hooked[d.hook_idx] = moved
		host_object_of(moved).hook_idx = d.hook_idx
	}
	pop(&rt.gc_hooked)
	d.hook_idx = -1
}

host_object_trace :: proc(rt: ^Runtime, o: ^Object, d: ^Host_Object) {
	c := host_class(rt, d.class_id)
	if c != nil && c.gc_mark != nil && d.hook_idx >= 0 {
		st := Host_Mark_State{rt = rt}
		c.gc_mark(rt, o, &st)
	}
}

// The counting pass over one hooked object (gc_mark_ext).
host_class_mark :: proc(rt: ^Runtime, o: ^Object, st: ^Host_Mark_State) {
	d := host_object_of(o)
	if d == nil {return}
	if c := host_class(rt, d.class_id); c != nil && c.gc_mark != nil {c.gc_mark(rt, o, st)}
}

// What a gc_mark callback does with each reference it reports (the C API's JS_MarkValue).
host_mark_value :: proc(st: ^Host_Mark_State, v: Value) {
	if !is_heap(v) {return}
	c := as_cell(v)
	if st.counting {
		if c.in_ext && c.ext > 0 {c.ext -= 1}
	} else {
		mark_cell(st.rt, c)
	}
}

host_object_free :: proc(rt: ^Runtime, o: ^Object, d: ^Host_Object) {
	if d.hook_idx >= 0 {hooked_remove(rt, d)}
	mem_free(rt, d, HOST_PAYLOAD_OFFSET + int(d.payload))
}

// Run the finalizers of the host objects the collection is about to free, while every cell is still
// allocated. They are listed: a walk of every cell for them cost as much as the marking.
host_run_finalizers :: proc(rt: ^Runtime) {
	kept := 0
	for o in rt.host_finals {
		if o.mark || o.pinned {
			rt.host_finals[kept] = o
			kept += 1
		} else {
			host_class(rt, host_object_of(o).class_id).finalizer(rt, o)
		}
	}
	resize(&rt.host_finals, kept)
}

// Runtime teardown: every host object's finalizer, before any cell is freed.
host_finalize_all :: proc(rt: ^Runtime) {
	for o in rt.host_finals {host_class(rt, host_object_of(o).class_id).finalizer(rt, o)}
	clear(&rt.host_finals)
}
