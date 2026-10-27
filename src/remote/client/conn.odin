package client

// One request at a time over the channel: the line is written, then lines are read until the answer to its id (events
// that arrive meanwhile are dropped). The transport is the system's (conn_<os>.odin: Conn, connect, disconnect,
// write_line, read_line): every wait there has a limit.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import "wb:remote"

Call_Error :: enum u8 { None, No_Server, Timeout, Closed, Server }

Reply :: struct {
	result:  string,   // JSON text of the result
	message: string,   // an error's message
	data:    string,   // an error's data (JSON text)
	code:    int,
}

// The next complete line of `pending` (without its newline), removed from it.
@(private)
take_line :: proc(pending: ^[dynamic]byte) -> (string, bool) {
	for b, i in pending^ {
		if b == '\n' {
			l := strings.clone(string(pending[:i]), context.temp_allocator)
			remove_range(pending, 0, i + 1)
			return l, true
		}
	}
	return "", false
}

// Sends a request and waits for its answer. `params` is JSON text ("" = none). The wait is `timeout_ms` (the server's own
// wait limits are shorter or equal: its timeout error comes first).
call :: proc(c: ^Conn, method, params: string, timeout_ms: int) -> (Reply, Call_Error) {
	c.next_id += 1
	id := c.next_id
	req := fmt.tprintf(`{{"id":%d,"method":%s,"params":%s}}`, id, remote.quote(method), params == "" ? "{}" : params)
	if e := write_line(c, req, timeout_ms); e != .None { return {}, e }
	deadline := time.tick_add(time.tick_now(), time.Duration(timeout_ms) * time.Millisecond)
	for {
		line, e := read_line(c, deadline)
		if e != .None { return {}, e }
		v, perr := json.parse(transmute([]byte)line, json.Specification.JSON, true, context.temp_allocator)
		obj, ok := v.(json.Object)
		if perr != .None || !ok { continue }
		if got, has := remote.param_int(obj, "id"); !has || got != id { continue }
		if errobj, is_err := remote.param_object(obj, "error"); is_err {
			r := Reply{code = 0}
			r.code, _ = remote.param_int(errobj, "code")
			r.message, _ = remote.param_string(errobj, "message")
			if at := strings.index(line, `"data":`); at >= 0 && strings.has_suffix(line, "}}") { r.data = line[at + len(`"data":`):len(line) - 2] }
			return r, .Server
		}
		// the result as the server wrote it (re-writing it would change its numbers): from "result": to the closing brace
		if at := strings.index(line, `"result":`); at >= 0 && strings.has_suffix(line, "}") { return Reply{result = line[at + len(`"result":`):len(line) - 1]}, .None }
		res, _ := obj["result"]
		s, merr := json.marshal(res, {}, context.temp_allocator)
		if merr != nil { return {}, .Closed }
		return Reply{result = string(s)}, .None
	}
}
