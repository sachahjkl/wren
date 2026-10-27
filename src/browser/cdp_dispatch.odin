package browser

// CDP / WebDriver BiDi message dispatch and the translation to and from the Wren command engine (remote_methods.odin).
// A tool's message becomes a Wren Call; the Wren reply (now, or later from an op) and Wren's events become the message
// the tool expects. See cdp.odin for the transport and the security.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "wb:remote"

////////////////////////////////
// Incoming messages

// One text frame (CDP or BiDi JSON). Routes by the method's namespace: a BiDi module name (session, browsingContext,
// script, input, network) makes it a BiDi message; otherwise it is CDP.
cdp_message :: proc(app: ^App, cl: ^Cdp_Client, msg: []byte) {
	root, err := json.parse(msg, json.Specification.JSON, true, context.temp_allocator)
	if err != .None { cdp_send_error(cl, "null", -32700, "parse error", false); return }
	obj, is_obj := root.(json.Object)
	if !is_obj { cdp_send_error(cl, "null", -32600, "a message is a JSON object", false); return }
	method, _ := remote.param_string(obj, "method")
	id_text := cdp_id_text(obj)
	bidi := cdp_is_bidi_method(method)
	if bidi { cl.flavor = .Bidi }
	params, _ := remote.param_object(obj, "params")
	if bidi {
		cdp_bidi_dispatch(app, cl, id_text, method, params)
	} else {
		cdp_cdp_dispatch(app, cl, id_text, method, params)
	}
}

cdp_is_bidi_method :: proc(method: string) -> bool {
	for ns in ([]string{"session.", "browsingContext.", "script.", "input.", "network.", "browser.", "log."}) {
		// CDP uses "Browser." / "Log." (capital); BiDi uses lowercase module names with a dot
		if strings.has_prefix(method, ns) && len(method) > len(ns) { return true }
	}
	return false
}

@(private = "file")
cdp_id_text :: proc(obj: json.Object) -> string {
	#partial switch v in obj["id"] {
	case json.Integer: return fmt.aprintf("%d", i64(v), allocator = context.temp_allocator)
	case json.Float:   return fmt.aprintf("%d", i64(v), allocator = context.temp_allocator)
	case json.String:  return remote.quote(string(v))
	}
	return "null"
}

////////////////////////////////
// CDP dispatch

@(private = "file")
cdp_cdp_dispatch :: proc(app: ^App, cl: ^Cdp_Client, id_text, method: string, params: json.Object) {
	// methods answered here, without the Wren engine (envelope-only)
	switch method {
	case "":
		cdp_send_error(cl, id_text, -32600, "a message has a \"method\"", false); return
	case "Target.setDiscoverTargets", "Page.enable", "Runtime.enable", "DOM.enable", "Network.enable",
	     "Log.enable", "Page.setLifecycleEventsEnabled", "Runtime.runIfWaitingForDebugger", "Emulation.setTouchEmulationEnabled",
	     "Network.setCacheDisabled", "Target.setRemoteLocations", "Performance.enable", "Inspector.enable":
		cdp_send_result(cl, id_text, "{}"); return
	case "Target.setAutoAttach":
		cl.auto_attach, _ = remote.param_bool(params, "autoAttach")
		cdp_send_result(cl, id_text, "{}"); return
	case "Target.attachToTarget":
		cdp_attach(app, cl, id_text, params); return
	case "Target.getTargetInfo":
		cdp_target_info(app, cl, id_text, params); return
	case "Browser.getVersion":
		cdp_send_result(cl, id_text, cdp_version_result(app)); return
	}
	// the rest go to the Wren engine with translated params; the reply is shaped when it comes (now or from an op)
	wmethod, wparams, kind, ok := cdp_to_wren(app, method, params)
	if !ok { cdp_send_error(cl, id_text, -32601, fmt.tprintf("method %s not supported by this adapter", method), false); return }
	cdp_run(app, cl, id_text, method, wmethod, wparams, kind, false)
}

// Translates a CDP method and its params to a Wren method and params (JSON text). `kind` says how to shape the reply.
@(private = "file")
cdp_to_wren :: proc(app: ^App, method: string, params: json.Object) -> (wmethod, wparams: string, kind: Cdp_Reply_Kind, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	tab := cdp_target_tab(params)   // a CDP "targetId" or the session's: Wren's tabId
	switch method {
	case "Page.navigate":
		url, _ := remote.param_string(params, "url")
		fmt.sbprintf(&b, `{{"url":%s,"wait":"load"%s}}`, remote.quote(url), cdp_tab_param(tab))
		return "Page.navigate", strings.to_string(b), .Passthrough, true
	case "Page.reload":
		ignore, _ := remote.param_bool(params, "ignoreCache")
		fmt.sbprintf(&b, `{{"ignoreCache":%v,"wait":"load"%s}}`, ignore, cdp_tab_param(tab))
		return "Page.reload", strings.to_string(b), .Passthrough, true
	case "Page.navigateToHistoryEntry":
		return "", "", .Empty, false   // not offered
	case "Page.getFrameTree":
		return "Wren.stats", "{}", .Empty, true   // the frame tree is synthesized in cdp_frame_tree; use an empty passthrough
	case "Page.captureScreenshot":
		fmt.sbprintf(&b, `{{"bytes":true,"target":"window"%s}}`, cdp_tab_param(tab))
		return "Page.captureScreenshot", strings.to_string(b), .Screenshot, true
	case "Page.bringToFront", "Page.setDownloadBehavior", "Page.stopLoading":
		if method == "Page.stopLoading" { return "Page.stopLoading", fmt.tprintf("{{%s}}", cdp_tab_param_bare(tab)), .Empty, true }
		return "", "{}", .Empty, false
	case "Runtime.evaluate", "Runtime.callFunctionOn":
		expr, _ := remote.param_string(params, "expression")
		if method == "Runtime.callFunctionOn" {
			// a thin shim: call the function with no bound object; the declaration is in functionDeclaration
			decl, _ := remote.param_string(params, "functionDeclaration")
			expr = fmt.tprintf("(%s).call(globalThis)", decl)
		}
		awaitp, _ := remote.param_bool(params, "awaitPromise")
		fmt.sbprintf(&b, `{{"expression":%s,"awaitPromise":%v%s}}`, remote.quote(expr), awaitp, cdp_tab_param(tab))
		return "Runtime.evaluate", strings.to_string(b), .Passthrough, true
	case "DOM.getDocument":
		return "DOM.getOuterHTML", fmt.tprintf(`{{"selector":"html"%s}}`, cdp_tab_param(tab)), .Passthrough, true
	case "DOM.getOuterHTML":
		sel, _ := remote.param_string(params, "selector", "html")
		return "DOM.getOuterHTML", fmt.tprintf(`{{"selector":%s%s}}`, remote.quote(sel), cdp_tab_param(tab)), .Passthrough, true
	case "DOM.querySelectorAll":
		sel, _ := remote.param_string(params, "selector")
		return "DOM.querySelectorAll", fmt.tprintf(`{{"selector":%s%s}}`, remote.quote(sel), cdp_tab_param(tab)), .Passthrough, true
	case "DOM.getBoxModel":
		sel, _ := remote.param_string(params, "selector")
		return "DOM.getBoxModel", fmt.tprintf(`{{"selector":%s%s}}`, remote.quote(sel), cdp_tab_param(tab)), .Passthrough, true
	case "CSS.getComputedStyleForNode":
		sel, _ := remote.param_string(params, "selector")
		return "CSS.getComputedStyleForNode", fmt.tprintf(`{{"selector":%s%s}}`, remote.quote(sel), cdp_tab_param(tab)), .Passthrough, true
	case "Input.dispatchMouseEvent":
		return "Input.dispatchMouseEvent", cdp_reencode(params), .Passthrough, true
	case "Input.dispatchKeyEvent":
		return "Input.dispatchKeyEvent", cdp_reencode(params), .Passthrough, true
	case "Input.insertText":
		text, _ := remote.param_string(params, "text")
		return "Input.insertText", fmt.tprintf(`{{"text":%s%s}}`, remote.quote(text), cdp_tab_param(tab)), .Passthrough, true
	case "Emulation.setDeviceMetricsOverride":
		w, _ := remote.param_int(params, "width")
		h, _ := remote.param_int(params, "height")
		scale, has_scale := remote.param_float(params, "deviceScaleFactor")
		bb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&bb, `{{"width":%d,"height":%d`, w, h)
		if has_scale && scale > 0 { fmt.sbprintf(&bb, `,"dpi":%d`, int(scale * 96 + 0.5)) }
		strings.write_string(&bb, "}")
		return "Browser.setWindowBounds", strings.to_string(bb), .Empty, true
	case "Emulation.setUserAgentOverride":
		ua, _ := remote.param_string(params, "userAgent")
		return "Wren.setPref", fmt.tprintf(`{{"name":"net.user_agent.override","value":%s}}`, remote.quote(ua)), .Empty, true
	case "Network.getResponseBody":
		return "", "{}", .Empty, false   // the body store is not exposed yet
	case "Network.setExtraHTTPHeaders":
		return "", "{}", .Empty, false
	case "Security.setIgnoreCertificateErrors":
		ignore, _ := remote.param_bool(params, "ignore")
		return "Wren.setPref", fmt.tprintf(`{{"name":"net.tls.ignore_cert_errors","value":%v,"override":true}}`, ignore), .Empty, true
	case "Browser.close":
		return "Browser.close", "{}", .Empty, true
	}
	return "", "", .Empty, false
}

// Dispatches a translated call through the Wren engine and shapes the answer (now or deferred).
cdp_run :: proc(app: ^App, cl: ^Cdp_Client, id_text, cdp_method, wmethod, wparams: string, kind: Cdp_Reply_Kind, bidi: bool) {
	cl.next_wren += 1
	wid := cl.next_wren
	params_obj: json.Object
	if wparams != "" {
		if root, err := json.parse(transmute([]byte)wparams, json.Specification.JSON, true, context.temp_allocator); err == .None {
			params_obj, _ = root.(json.Object)
		}
	}
	c := Call{conn = cl.conn, id = cdp_wid_text(wid), method = wmethod, params = params_obj}
	cl.pending[wid] = Cdp_Pending{kind = kind, msg_id = strings.clone(id_text), method = strings.clone(cdp_method), bidi = bidi}
	if !remote_reads_only(wmethod) { request_frames(app, 2) }
	rep := remote_dispatch(app, &c)
	if rep.deferred { return }   // an op will answer through remote_send -> cdp_deliver
	// answered at once: deliver it the same way the deferred path would
	line := rep.code != 0 ? remote.response_error(c.id, rep.code, rep.message, rep.data) : remote.response_ok(c.id, rep.result)
	cdp_deliver(cl.conn, line)
}

@(private = "file")
cdp_wid_text :: proc(wid: u64) -> string { return fmt.tprintf("%d", wid) }

////////////////////////////////
// Delivery: a Wren reply line (remote_send routed it here by the CDP_CONN_TAG) turned into a CDP / BiDi message.

cdp_deliver :: proc(conn: u64, line: string) {
	c := &the_cdp
	tcp_id := conn & ~CDP_CONN_TAG
	cl := c.clients[tcp_id]
	if cl == nil { return }
	root, err := json.parse(transmute([]byte)line, json.Specification.JSON, true, context.temp_allocator)
	if err != .None { return }
	obj, _ := root.(json.Object)
	wid := cdp_parse_wid(obj)
	p, ok := cl.pending[wid]
	if !ok { return }
	delete_key(&cl.pending, wid)
	defer { delete(p.msg_id); delete(p.method) }

	if errobj, has_err := obj["error"].(json.Object); has_err {
		code, _ := remote.param_int(errobj, "code")
		message, _ := remote.param_string(errobj, "message")
		cdp_send_error(cl, p.msg_id, code, message, p.bidi)
		return
	}
	result, _ := obj["result"].(json.Object)
	shaped := cdp_shape_result(the_app, cl, p, result)
	cdp_send_result_raw(cl, p.msg_id, shaped, p.bidi)
}

@(private = "file")
cdp_parse_wid :: proc(obj: json.Object) -> u64 {
	#partial switch v in obj["id"] {
	case json.Integer: return u64(v)
	case json.Float:   return u64(v)
	case json.String:  if n, ok := strconv.parse_u64(string(v)); ok { return n }
	}
	return 0
}

// The CDP (or BiDi) result object for a Wren result, by the pending kind.
@(private = "file")
cdp_shape_result :: proc(app: ^App, cl: ^Cdp_Client, p: Cdp_Pending, result: json.Object) -> string {
	switch p.kind {
	case .Passthrough:
		return cdp_object_text(result)
	case .Empty:
		return "{}"
	case .Screenshot:
		data, _ := remote.param_string(result, "data")
		return fmt.tprintf(`{{"data":%s}}`, remote.quote(data))
	case .Targets:
		return cdp_targets_result(app, result)
	case .Bidi_Navigate:
		url, _ := remote.param_string(result, "url")
		return fmt.tprintf(`{{"navigation":null,"url":%s}}`, remote.quote(url))
	case .Bidi_Evaluate:
		return cdp_bidi_evaluate_result(result)
	case .Bidi_Tree:
		return cdp_bidi_tree_result(app)
	case .Bidi_Screenshot:
		data, _ := remote.param_string(result, "data")
		return fmt.tprintf(`{{"data":%s}}`, remote.quote(data))
	case .Bidi_Empty:
		return "{}"
	}
	return "{}"
}

////////////////////////////////
// Sending

cdp_send_result :: proc(cl: ^Cdp_Client, id_text, result: string) {
	cdp_send_result_raw(cl, id_text, result, cl.flavor == .Bidi)
}

cdp_send_result_raw :: proc(cl: ^Cdp_Client, id_text, result: string, bidi: bool) {
	b := strings.builder_make(context.temp_allocator)
	if bidi {
		fmt.sbprintf(&b, `{{"type":"success","id":%s,"result":%s}}`, id_text, result == "" ? "{}" : result)
	} else {
		fmt.sbprintf(&b, `{{"id":%s,"result":%s}}`, id_text, result == "" ? "{}" : result)
	}
	cdp_frame_text(cl, strings.to_string(b))
}

cdp_send_error :: proc(cl: ^Cdp_Client, id_text: string, code: int, message: string, bidi: bool) {
	b := strings.builder_make(context.temp_allocator)
	if bidi {
		fmt.sbprintf(&b, `{{"type":"error","id":%s,"error":"unknown error","message":`, id_text)
		remote.write_json_string(&b, message)
		strings.write_string(&b, "}")
	} else {
		fmt.sbprintf(&b, `{{"id":%s,"error":{{"code":%d,"message":`, id_text, code)
		remote.write_json_string(&b, message)
		strings.write_string(&b, "}}")
	}
	cdp_frame_text(cl, strings.to_string(b))
}

////////////////////////////////
// Helpers

// The JSON text of a parsed object (re-serialized; the engine's results are small).
@(private = "file")
cdp_object_text :: proc(obj: json.Object) -> string {
	data, err := json.marshal(obj, allocator = context.temp_allocator)
	if err != nil { return "{}" }
	return string(data)
}

// Re-encode a params object as JSON text to pass through to Wren unchanged.
@(private = "file")
cdp_reencode :: proc(obj: json.Object) -> string {
	data, err := json.marshal(obj, allocator = context.temp_allocator)
	if err != nil { return "{}" }
	return string(data)
}

// The Wren tabId for a CDP targetId (decimal) in the params, or 0 (the current tab).
@(private = "file")
cdp_target_tab :: proc(params: json.Object) -> u64 {
	if s, ok := remote.param_string(params, "targetId"); ok { if n, pok := strconv.parse_u64(s); pok { return n } }
	return 0
}

// `,"tabId":N` when tab != 0, else "" (a fragment inside a Wren params object).
@(private = "file")
cdp_tab_param :: proc(tab: u64) -> string {
	if tab == 0 { return "" }
	return fmt.tprintf(`,"tabId":%d`, tab)
}

@(private = "file")
cdp_tab_param_bare :: proc(tab: u64) -> string {
	if tab == 0 { return "" }
	return fmt.tprintf(`"tabId":%d`, tab)
}
