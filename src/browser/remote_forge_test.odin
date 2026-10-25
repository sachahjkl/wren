package browser

import "core:fmt"
import "core:strings"
import "core:testing"

// What a page can and cannot do to the answers of `wren ctl eval` (security review of 2026-10-25, finding 5): the line goes
// through the page's console.log, so the page sees it and can write one like it.

@(private = "file")
answer_line :: proc(id: int, value: string) -> string {
	return strings.concatenate({REMOTE_ANSWER, `{"t":"string","v":`, value, `,"ok":1,"id":`, fmt.tprintf("%d", id), `}`}, context.temp_allocator)
}

@(private = "file")
reset_remote :: proc() {
	r := &the_remote
	delete(r.sync_text); delete(r.stash_text)
	r^ = {}
}

@(private = "file")
only_marked_lines_are_answers :: proc(t: ^testing.T) {
	defer reset_remote()
	the_remote.active = true
	testing.expect(t, !remote_take_console("hello", 1))
	testing.expect(t, !remote_take_console(`{"id":1}`, 1))
	testing.expect(t, remote_take_console(answer_line(1, `"x"`), 1), "a marked line never reaches the console")
	testing.expect(t, remote_take_console(strings.concatenate({REMOTE_ANSWER, "not json"}, context.temp_allocator), 1))
	the_remote.active = false
	testing.expect(t, !remote_take_console(answer_line(1, `"x"`), 1), "with no remote control, a page's line is a page's line")
}

@(private = "file")
an_answer_counts_for_its_own_tab_and_its_first_time_only :: proc(t: ^testing.T) {
	defer reset_remote()
	r := &the_remote
	r.active = true
	// a question waits for its answer in tab 1
	r.sync_id, r.sync_tab = 5, 1
	testing.expect(t, remote_take_console(answer_line(5, `"from tab 2"`), 2))
	testing.expect(t, !r.sync_done, "another tab's page cannot answer it")
	testing.expect(t, remote_take_console(answer_line(6, `"other id"`), 1))
	testing.expect(t, !r.sync_done, "nor can a line for a question nobody asked")
	testing.expect(t, remote_take_console(answer_line(5, `"real"`), 1))
	testing.expect(t, r.sync_done && strings.contains(r.sync_text, `"real"`), r.sync_text)
	testing.expect(t, remote_take_console(answer_line(5, `"second"`), 1))
	testing.expect(t, strings.contains(r.sync_text, `"real"`) && !strings.contains(r.sync_text, "second"), "the first answer stays")

	// a command that is starting: its answer may come before it waits (the stash), from its tab, once
	r.start_id, r.start_tab = 9, 1
	testing.expect(t, remote_take_console(answer_line(9, `"from tab 3"`), 3))
	testing.expect_value(t, r.stash_id, 0)
	testing.expect(t, remote_take_console(answer_line(10, `"not mine"`), 1))
	testing.expect_value(t, r.stash_id, 0)
	testing.expect(t, remote_take_console(answer_line(9, `"first"`), 1))
	testing.expect(t, remote_take_console(answer_line(9, `"second"`), 1))
	testing.expect_value(t, r.stash_id, 9)
	testing.expect(t, strings.contains(r.stash_text, `"first"`), r.stash_text)

	// and nothing is kept when nothing is starting
	delete(r.stash_text); r.stash_text, r.stash_id, r.start_id = "", 0, 0
	testing.expect(t, remote_take_console(answer_line(9, `"late"`), 1))
	testing.expect_value(t, r.stash_id, 0)
}

@(private = "file")
an_op_waiting_in_another_tab_is_left_alone :: proc(t: ^testing.T) {
	defer reset_remote()
	r := &the_remote
	r.active = true
	op := new(Remote_Op)
	op.kind, op.eval_id, op.tab = .Eval, 12, 1
	append(&r.ops, op)
	defer { delete(r.ops); free(op) }
	testing.expect(t, remote_take_console(answer_line(12, `"forged by tab 2"`), 2))
	testing.expect_value(t, len(r.ops), 1)   // still waiting for its own tab's answer
}

// (one test for the three: they share the_remote, and tests run in parallel)
@(test)
answers_are_taken_from_their_own_tab_only :: proc(t: ^testing.T) {
	only_marked_lines_are_answers(t)
	an_answer_counts_for_its_own_tab_and_its_first_time_only(t)
	an_op_waiting_in_another_tab_is_left_alone(t)
}

@(test)
a_value_is_one_json_value_on_one_line :: proc(t: ^testing.T) {
	good := []string{
		`0`, `-1`, `1.5`, `-0.25e+10`, `1E3`, `"a"`, `""`, `"a\"b\\c\/d\b\f\n\r\t\u00e9\uD83D"`, `"é€😀"`, `null`, `true`, `false`,
		`[]`, `{}`, `[1,2,3]`, `{"a":1}`, `{"a":[{"b":null},"c"],"d":{}}`, `[ 1 , 2 ]`, `{ "a" : 1 }`, `"\u2028"`,
	}
	for s in good { testing.expectf(t, json_value_line(s), "%q is JSON", s) }
	bad := []string{
		``, ` `, "1\n", "\n1", "1\r", "\t1", "[1,\n2]", "\"a\nb\"", "\"a\tb\"", "\"a\x01b\"", "\"\x7f\"" + "\x00",
		"1\n{\"id\":999,\"result\":{\"x\":1}}", `1 2`, `1,2`, `{"a":1}{"b":2}`, `{"a":1} x`, `[1,]`, `{"a":1,}`, `{a:1}`, `{'a':1}`, `'x'`,
		`01`, `+1`, `.5`, `1.`, `1e`, `1e+`, `-`, `--1`, `NaN`, `Infinity`, `-Infinity`, `undefined`, `tru`, `nul`, `"abc`, `"\x"`, `"\u12"`, `"\u12g4"`,
		`[`, `{`, `{"a"`, `{"a":`, `{"a":1`, `[1`, `/* c */1`, `1 // c`, "\"\xff\"", "\"\xc3\"", "\xef\xbb\xbf1",
	}
	for s in bad { testing.expectf(t, !json_value_line(s), "%q is not one JSON value on one line", s) }
	deep := strings.concatenate({strings.repeat("[", 600, context.temp_allocator), strings.repeat("]", 600, context.temp_allocator)}, context.temp_allocator)
	testing.expect(t, !json_value_line(deep), "nesting is bounded")
	ok := strings.concatenate({strings.repeat("[", 100, context.temp_allocator), strings.repeat("]", 100, context.temp_allocator)}, context.temp_allocator)
	testing.expect(t, json_value_line(ok))
}

@(test)
a_forged_value_makes_an_error_not_a_second_line :: proc(t: ^testing.T) {
	// the answer line is JSON; its "v" is a string holding the value's JSON text. A page that wrote a real line break in it:
	rep := eval_reply_text(`{"id":1,"ok":1,"t":"string","v":"1\n{\"id\":999,\"result\":{\"x\":1}}"}`)
	testing.expect(t, rep.code != 0, "refused, not passed on")
	testing.expect(t, !strings.contains(rep.message, "999"), rep.message)
	// what JSON.stringify makes of a string with a line break has none (it is \n, two characters)
	rep = eval_reply_text(`{"id":1,"ok":1,"t":"string","v":"\"a\\nb\""}`)
	testing.expect_value(t, rep.code, 0)
	testing.expect(t, strings.contains(rep.result, `"value":"a\nb"`) && !strings.contains(rep.result, "\n"), rep.result)
	rep = eval_reply_text(`{"id":1,"ok":1,"t":"number","v":"4"}`)
	testing.expect_value(t, rep.code, 0)
	testing.expect(t, strings.contains(rep.result, `"value":4`), rep.result)
}