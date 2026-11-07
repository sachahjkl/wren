package base

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file") TEST_SPANS :: 2
@(private = "file") TEST_LABEL_BYTES :: 16

// A span says what it was and where: its kind, its label as it was when it was added (a label copied outlives its text), the line of a task's
// poster and whom it works for; past the table's room nothing is written over.
@(test)
spans_keep_what_was_added_and_stop_at_their_room :: proc(t: ^testing.T) {
	path := fmt.aprintf("%s/wren_spans_test_%d.tsv", os.temp_directory(context.temp_allocator) or_else ".", os.get_pid(), allocator = process_allocator())
	defer delete(path, process_allocator())
	defer os.remove(path)
	spans_open(strings.clone(path, process_allocator()), TEST_SPANS, TEST_LABEL_BYTES)
	defer spans_close()

	label := [?]u8{'a', '.', 'j', 's'}
	at := span_now()
	span_add(.Script, at, string(label[:]), copy_label = true)
	label[0] = 'z'
	span_add(.Task, at, "loop.odin", 42, work = Work{page = 3, origin = 2, class = .Arrival, third_party = true})
	span_add(.Gc, at, "past the room")
	spans_write()

	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, err == nil, "the file is written")
	text := string(data)
	testing.expect(t, strings.count(text, "\n") == TEST_SPANS, "one line a span, the room's worth")
	testing.expect(t, strings.contains(text, "\tScript\ta.js\n"), "the label as it was")
	testing.expect(t, strings.contains(text, "\tTask\tloop.odin:42\tArrival\t3\t2\ttrue\n"), "a task names its poster's line and whom it works for")
	testing.expect(t, !strings.contains(text, "past the room"), "what has no room is dropped")
}
