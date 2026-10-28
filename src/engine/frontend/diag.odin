package frontend

// Diagnostics and source positions. QuickJS reports a syntax error with a message, a line number (1-based) and a
// column number (1-based bytes-ish); the parse judge compares our verdict (did it error? with what message?) to
// QuickJS's. We keep the message wording close to QuickJS where it is stable.
//
// A Source_Pos is a byte offset into the source plus the precomputed line and column so an error can be reported
// without rescanning. Columns count UTF-16-ish code units the way QuickJS's col_num does (it advances one per
// byte of a line except it is really tracking the source pointer); for our purposes the byte column is what the
// debug table and messages use, and we keep a code-point column too for user-facing display.

Source_Pos :: struct {
	offset: u32, // byte offset from the start of the source
	line:   u32, // 1-based line
	col:    u32, // 1-based column (code points on the line)
}

// A parse/compile error. `ok` false means a real error; the message is QuickJS-worded where possible.
Error :: struct {
	message: string,
	pos:     Source_Pos,
	is_error: bool,
}

no_error :: Error{is_error = false}

make_error :: proc(msg: string, pos: Source_Pos) -> Error {
	return Error{message = msg, pos = pos, is_error = true}
}

is_err :: #force_inline proc(e: Error) -> bool {
	return e.is_error
}
