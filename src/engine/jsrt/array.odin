package jsrt

// Array exotic objects.
//
// The fast path stores elements in a dense Value slice (Array_Data.dense) with a separate `length`.
// Integer-indexed reads/writes within the dense range are O(1) and never touch the shape. Writing far
// past the end, or a non-index property, is a "sparse" trigger: the array keeps `length` but further
// index storage falls back to ordinary shape properties. "length" is a synthetic own property handled
// in exotic_get_own / exotic_set_own, not a shape slot.

// Create an Array with `n` elements, all `undefined` (dense). The length is n.
array_new :: proc(rt: ^Runtime, n: u32) -> ^Object {
	// Prototype wiring is done by the caller when a realm is available; the serializer passes the
	// realm's array_proto. Here we leave proto nil and let object_new set the empty shape; callers
	// that need Array.prototype use array_new_in_realm.
	obj := object_new(rt, nil)
	if obj == nil {return nil}
	dense := make([dynamic]Value, int(n), rt.allocator)
	for i in 0 ..< int(n) {dense[i] = UNDEFINED}
	obj.exotic = Array_Data{dense = dense, length = n, sparse = false}
	return obj
}

array_new_in_realm :: proc(ctx: ^Context, n: u32) -> ^Object {
	obj := array_new(ctx.rt, n)
	if obj == nil {return nil}
	// Re-point the shape's prototype at Array.prototype.
	shape_set_proto(ctx.rt, obj, ctx.realm.array_proto)
	return obj
}

// Repoint an object's prototype (used during realm setup and array creation). Clones the shape if it
// is shared so other objects keep their prototype.
shape_set_proto :: proc(rt: ^Runtime, obj: ^Object, proto: ^Object) {
	uniq := shape_make_unique(rt, obj.shape)
	if uniq != obj.shape {
		shape_unref(rt, obj.shape)
		obj.shape = uniq
	}
	old := obj.shape.proto
	obj.shape.proto = proto
	if proto != nil {object_ref(proto)}
	if old != nil {object_unref(rt, old)}
}

// Push one element (consumes v). Grows the dense store.
array_push :: proc(rt: ^Runtime, obj: ^Object, v: Value) {
	ad := &obj.exotic.(Array_Data)
	append(&ad.dense, v)
	ad.length = u32(len(ad.dense))
}

// Fast dense get; returns (value, true) if the index is in the dense range.
array_get_index :: proc(obj: ^Object, i: u32) -> (Value, bool) {
	ad, ok := &obj.exotic.(Array_Data)
	if !ok {return UNDEFINED, false}
	if !ad.sparse && i < u32(len(ad.dense)) {
		return ad.dense[i], true
	}
	return UNDEFINED, false
}

// Fast dense set within or just past the end (consumes v). Returns false if the write should fall
// back to the sparse / shape path.
array_set_index :: proc(rt: ^Runtime, obj: ^Object, i: u32, v: Value) -> bool {
	ad := &obj.exotic.(Array_Data)
	if ad.sparse {return false}
	n := u32(len(ad.dense))
	if i < n {
		value_free(rt, ad.dense[i])
		ad.dense[i] = v
		return true
	}
	if i == n {
		append(&ad.dense, v)
		ad.length = i + 1
		return true
	}
	// A gap of more than the growth heuristic makes the array sparse.
	if i - n < 1024 {
		for _ in n ..< i {append(&ad.dense, UNDEFINED)}
		append(&ad.dense, v)
		ad.length = i + 1
		return true
	}
	ad.sparse = true
	if i + 1 > ad.length {ad.length = i + 1}
	return false
}

// Set the array length, truncating the dense store (freeing dropped elements).
array_set_length :: proc(rt: ^Runtime, obj: ^Object, new_len: u32) {
	ad := &obj.exotic.(Array_Data)
	if !ad.sparse && new_len < u32(len(ad.dense)) {
		for i in new_len ..< u32(len(ad.dense)) {
			value_free(rt, ad.dense[i])
		}
		resize(&ad.dense, int(new_len))
	}
	ad.length = new_len
}
