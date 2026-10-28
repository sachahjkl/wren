// qjs_errors.odin: the exceptions bindings throw (Web IDL "simple exceptions" and DOMException) and the mapping from
// the browser's Error codes (api/web.widl) to them. Ported from native/js/engine/qjs_errors.c, same symbols and
// messages. wj_throw_type / wj_throw_range are the engine's own throwers (errors.odin).
package wj

@(private = "file")
Dom_Code :: struct { name: cstring, code: i32 }

// DOMException's legacy codes (Web IDL "DOMException names table")
@(private = "file")
dom_codes := [?]Dom_Code{
	{"IndexSizeError", 1}, {"HierarchyRequestError", 3}, {"WrongDocumentError", 4}, {"InvalidCharacterError", 5},
	{"NoModificationAllowedError", 7}, {"NotFoundError", 8}, {"NotSupportedError", 9}, {"InUseAttributeError", 10},
	{"InvalidStateError", 11}, {"SyntaxError", 12}, {"InvalidModificationError", 13}, {"NamespaceError", 14},
	{"InvalidAccessError", 15}, {"TypeMismatchError", 17}, {"SecurityError", 18}, {"NetworkError", 19},
	{"AbortError", 20}, {"URLMismatchError", 21}, {"QuotaExceededError", 22}, {"TimeoutError", 23},
	{"InvalidNodeTypeError", 24}, {"DataCloneError", 25},
}

@(export, link_name = "wj_dom_exception_code")
wj_dom_exception_code :: proc "c" (name: cstring) -> i32 {
	for &d in dom_codes {
		if strcmp(([^]u8)(rawptr(d.name)), ([^]u8)(rawptr(name))) == 0 { return d.code }
	}
	return 0
}

@(export, link_name = "wj_throw_dom")
wj_throw_dom :: proc "c" (ctx: ^Context, name: cstring, message: cstring) -> JSValue {
	e := wj_new_dom_exception(ctx, name, message != nil ? message : "")
	if is_exception(e) { return e }
	return JS_Throw(ctx, e)
}

@(export, link_name = "wj_throw_unsupported")
wj_throw_unsupported :: proc "c" (ctx: ^Context, iface: cstring, member: cstring) -> JSValue {
	msg: [256]u8
	snprintf(&msg[0], len(msg), "%s.%s is not supported by this browser", iface, member)
	return wj_throw_dom(ctx, "NotSupportedError", cstring(&msg[0]))
}

// the message the browser recorded with the error (web.Exception_message), NUL-terminated in `buf`
@(private = "file")
last_message :: proc "contextless" (buf: []u8) {
	cap := len(buf) - 1
	n := int(wr_Exception_message(raw_data(buf), u32(cap)))
	if n < 0 { n = 0 }
	if n > cap { n = cap }
	buf[n] = 0
}

@(export, link_name = "wj_throw_status")
wj_throw_status :: proc "c" (ctx: ^Context, status: i32, what: cstring) -> JSValue {
	buf: [600]u8
	last_message(buf[:])
	if buf[0] == 0 && what != nil { snprintf(&buf[0], len(buf), "%s failed", what) }
	msg := cstring(&buf[0])
	dom: cstring
	#partial switch wr_Error(status) {
	case .Invalid_Handle: return JS_ThrowTypeError(ctx, "%s", buf[0] != 0 ? msg : "the object is no longer alive")
	case .Type: return JS_ThrowTypeError(ctx, "%s", msg)
	case .Range: return JS_ThrowRangeError(ctx, "%s", msg)
	case .Hierarchy: dom = "HierarchyRequestError"
	case .Not_Found: dom = "NotFoundError"
	case .Invalid_Argument, .Attached, .Invalid_State: dom = "InvalidStateError"
	case .Security: dom = "SecurityError"
	case .Quota: dom = "QuotaExceededError"
	case .Not_Supported: dom = "NotSupportedError"
	case .Syntax: dom = "SyntaxError"
	case .Abort: dom = "AbortError"
	case .Timeout: dom = "TimeoutError"
	case .Data_Clone: dom = "DataCloneError"
	case .Network: dom = "NetworkError"
	case .Encoding: dom = "EncodingError"
	case .Index_Size: dom = "IndexSizeError"
	case .Not_Allowed: dom = "NotAllowedError"
	case .Invalid_Access: dom = "InvalidAccessError"
	case .Invalid_Character: dom = "InvalidCharacterError"
	case .Namespace: dom = "NamespaceError"
	case .In_Use_Attribute: dom = "InUseAttributeError"
	case .Wrong_Document: dom = "WrongDocumentError"
	case .Invalid_Node_Type: dom = "InvalidNodeTypeError"
	case .Invalid_Modification: dom = "InvalidModificationError"
	case .No_Modification_Allowed: dom = "NoModificationAllowedError"
	case: return JS_ThrowInternalError(ctx, "%s (error %d)", msg, status)
	}
	return wj_throw_dom(ctx, dom, msg)
}
