package adblock

// One-call helpers: lists in, engine out.

List_Text :: struct {
	id:   u8,
	name: string,
	text: string,
}

// Compiles lists to a blob (see `engine_load` to use it, or write it to a file).
compile :: proc(lists: []List_Text, env := Env{}, include: Include_Proc = nil, include_user: rawptr = nil, allocator := context.allocator) -> []byte {
	b: Builder
	builder_init(&b, env)
	defer builder_destroy(&b)
	b.include, b.include_user = include, include_user
	for l in lists { builder_add(&b, l.id, l.name, l.text) }
	return builder_build(&b, allocator)
}

// Compiles and loads in one step (the engine owns its blob).
engine_from_lists :: proc(lists: []List_Text, env := Env{}, allocator := context.allocator) -> (^Engine, Load_Error) {
	blob := compile(lists, env, allocator = allocator)
	e, err := engine_load(blob, true, false, allocator)
	if err != .None { delete(blob, allocator) }
	return e, err
}

engine_from_text :: proc(text: string, allocator := context.allocator) -> ^Engine {
	e, _ := engine_from_lists([]List_Text{{1, "test", text}}, allocator = allocator)
	return e
}
