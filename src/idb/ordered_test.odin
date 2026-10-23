package idb

import "core:bytes"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"

@(test)
ordered_matches_a_sorted_reference :: proc(t: ^testing.T) {
	o: Ordered
	ordered_init(&o, context.allocator)
	defer ordered_destroy(&o)
	gen := rand.create(7)
	context.random_generator = rand.default_random_generator(&gen)
	ref := make(map[string]int, context.temp_allocator)
	vals := make([dynamic]^int, context.temp_allocator)
	for i in 0 ..< 6000 {
		k := fmt.tprintf("k%04d", rand.int_max(2500))
		v := new(int, context.temp_allocator)
		v^ = i
		append(&vals, v)
		if rand.int_max(3) == 0 {
			old, found := ordered_delete(&o, transmute([]byte)k)
			_, had := ref[k]
			testing.expect_value(t, found, had)
			if found { testing.expect_value(t, (^int)(old)^, ref[k]) }
			delete_key(&ref, k)
		} else {
			old, replaced := ordered_put(&o, transmute([]byte)k, v)
			prev, had := ref[k]
			testing.expect_value(t, replaced, had)
			if replaced { testing.expect_value(t, (^int)(old)^, prev) }
			ref[k] = i
		}
	}
	testing.expect(t, ordered_check(&o), "invariants")
	testing.expect_value(t, o.count, len(ref))
	sorted := make([dynamic]string, context.temp_allocator)
	for k in ref { append(&sorted, k) }
	slice.sort(sorted[:])
	p := ordered_first(&o)
	for k in sorted {
		testing.expect(t, pos_valid(&o, p), "enough entries")
		key, val := pos_entry(&o, p)
		testing.expect_value(t, string(key), k)
		testing.expect_value(t, (^int)(val)^, ref[k])
		pos_next(&o, &p)
	}
	testing.expect(t, !pos_valid(&o, p), "the end")
	// seek: first >= and first >
	for _ in 0 ..< 300 {
		probe := fmt.tprintf("k%04d", rand.int_max(2600))
		for strict in ([]bool{false, true}) {
			want := -1
			for k, i in sorted {
				c := bytes.compare(transmute([]byte)k, transmute([]byte)probe)
				if c > 0 || (c == 0 && !strict) { want = i; break }
			}
			q := ordered_seek(&o, transmute([]byte)probe, strict)
			if want < 0 {
				testing.expect(t, !pos_valid(&o, q), "seek past the end")
			} else {
				testing.expect(t, pos_valid(&o, q), "seek lands")
				if pos_valid(&o, q) {
					key, _ := pos_entry(&o, q)
					testing.expect_value(t, string(key), sorted[want])
				}
			}
		}
	}
	// backwards from the end
	e := ordered_end(&o)
	for i := len(sorted) - 1; i >= 0; i -= 1 {
		testing.expect(t, pos_prev(&o, &e), "prev")
		key, _ := pos_entry(&o, e)
		testing.expect_value(t, string(key), sorted[i])
	}
	testing.expect(t, !pos_prev(&o, &e), "before the first")
}

@(test)
ordered_empty_and_clear :: proc(t: ^testing.T) {
	o: Ordered
	ordered_init(&o, context.allocator)
	defer ordered_destroy(&o)
	testing.expect(t, !pos_valid(&o, ordered_seek(&o, {1})), "empty seek")
	_, found := ordered_delete(&o, {1})
	testing.expect(t, !found, "delete from empty")
	for i in 0 ..< 1000 { ordered_put(&o, {byte(i >> 8), byte(i)}, nil) }
	ordered_clear(&o)
	testing.expect_value(t, o.count, 0)
	testing.expect(t, !pos_valid(&o, ordered_first(&o)), "cleared")
	ordered_put(&o, {5}, nil)
	testing.expect_value(t, o.count, 1)
}
