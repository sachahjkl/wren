package browser

// WebDriver BiDi over the same WebSocket transport (cdp.odin) and the same Wren command engine. A small subset: the
// session module, browsingContext (navigate, getTree, captureScreenshot), script (evaluate, callFunction) and a basic
// network / log event feed. A BiDi context id is a Wren tab id as a decimal string, as the CDP targetId is.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "wb:remote"

cdp_bidi_dispatch :: proc(app: ^App, cl: ^Cdp_Client, id_text, method: string, params: json_obj) {
	switch method {
	case "session.new":
		// announce the capabilities a BiDi client expects; the session is flat (one browser, tabs are contexts)
		cdp_send_result_raw(cl, id_text, fmt.tprintf(`{{"sessionId":"wren","capabilities":{{"browserName":"Wren","browserVersion":"%s","acceptInsecureCerts":false,"userAgent":%s}}}}`,
			APP_VERSION, remote.quote(fmt.tprintf("Wren/%s", APP_VERSION))), true)
	case "session.status":
		cdp_send_result_raw(cl, id_text, `{"ready":true,"message":"ready"}`, true)
	case "session.subscribe", "session.unsubscribe", "session.end":
		cdp_send_result_raw(cl, id_text, "{}", true)
	case "browser.close":
		cdp_run(app, cl, id_text, method, "Browser.close", "{}", .Bidi_Empty, true)
	case "browsingContext.getTree":
		cdp_run(app, cl, id_text, method, "Wren.stats", "{}", .Bidi_Tree, true)
	case "browsingContext.navigate":
		url, _ := remote.param_string(params, "url")
		tab := cdp_bidi_context(params)
		cdp_run(app, cl, id_text, method, "Page.navigate", fmt.tprintf(`{{"url":%s,"wait":"load"%s}}`, remote.quote(url), cdp_bidi_tab_param(tab)), .Bidi_Navigate, true)
	case "browsingContext.reload":
		tab := cdp_bidi_context(params)
		cdp_run(app, cl, id_text, method, "Page.reload", fmt.tprintf(`{{"wait":"load"%s}}`, cdp_bidi_tab_param(tab)), .Bidi_Empty, true)
	case "browsingContext.captureScreenshot":
		tab := cdp_bidi_context(params)
		cdp_run(app, cl, id_text, method, "Page.captureScreenshot", fmt.tprintf(`{{"bytes":true,"target":"window"%s}}`, cdp_bidi_tab_param(tab)), .Bidi_Screenshot, true)
	case "browsingContext.create":
		t := tab_open(app, "", origin = .User)
		cdp_send_result_raw(cl, id_text, fmt.tprintf(`{{"context":"%d"}}`, t.id), true)
	case "browsingContext.close":
		tab := cdp_bidi_context(params)
		if t := tab_by_id(app, tab); t != nil { tab_close_tab(app, t) }
		cdp_send_result_raw(cl, id_text, "{}", true)
	case "script.evaluate", "script.callFunction":
		expr := ""
		if method == "script.evaluate" {
			expr, _ = remote.param_string(params, "expression")
		} else {
			decl, _ := remote.param_string(params, "functionDeclaration")
			expr = fmt.tprintf("(%s).call(globalThis)", decl)
		}
		tab := cdp_bidi_context(params)
		awaitp, _ := remote.param_bool(params, "awaitPromise", true)
		cdp_run(app, cl, id_text, method, "Runtime.evaluate", fmt.tprintf(`{{"expression":%s,"awaitPromise":%v%s}}`, remote.quote(expr), awaitp, cdp_bidi_tab_param(tab)), .Bidi_Evaluate, true)
	case "input.performActions":
		// a thin bridge: BiDi action sequences are not decomposed here; acknowledge so a tool proceeds (it may also use CDP Input)
		cdp_send_result_raw(cl, id_text, "{}", true)
	case "input.releaseActions":
		cdp_send_result_raw(cl, id_text, "{}", true)
	case:
		cdp_send_error(cl, id_text, -32601, fmt.tprintf("BiDi method %s not supported by this adapter", method), true)
	}
}

// A BiDi "context" (a Wren tab id as a decimal string), 0 for the current tab.
@(private = "file")
cdp_bidi_context :: proc(params: json_obj) -> u64 {
	if s, ok := remote.param_string(params, "context"); ok { if n, pok := strconv.parse_u64(s); pok { return n } }
	return 0
}

@(private = "file")
cdp_bidi_tab_param :: proc(tab: u64) -> string {
	if tab == 0 { return "" }
	return fmt.tprintf(`,"tabId":%d`, tab)
}

// Wren's {result:{type,value}} to BiDi's {type:"success",result:{type,value}}: the inner value is passed through as a
// remote value of the matching primitive type (strings, numbers, booleans, null); anything else is a string.
cdp_bidi_evaluate_result :: proc(wren_result: json_obj) -> string {
	inner, _ := wren_result["result"].(json_obj)
	kind, _ := remote.param_string(inner, "type")
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"type":"success","result":`)
	switch kind {
	case "string":
		v, _ := remote.param_string(inner, "value")
		fmt.sbprintf(&b, `{{"type":"string","value":%s}}`, remote.quote(v))
	case "number":
		v, _ := remote.param_float(inner, "value")
		fmt.sbprintf(&b, `{{"type":"number","value":%v}}`, v)
	case "boolean":
		v, _ := remote.param_bool(inner, "value")
		fmt.sbprintf(&b, `{{"type":"boolean","value":%v}}`, v)
	case "undefined", "":
		strings.write_string(&b, `{"type":"undefined"}`)
	case:
		strings.write_string(&b, `{"type":"null"}`)
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// browsingContext.getTree: one context per top-level tab.
cdp_bidi_tree_result :: proc(app: ^App) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"contexts":[`)
	first := true
	for t in tabs_all(app) {
		if t.frame != nil { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		fmt.sbprintf(&b, `{{"context":"%d","url":%s,"children":[],"userContext":"default"}}`, t.id, remote.quote(t.url))
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// A Wren event to a BiDi client (browsingContext.load, log.entryAdded).
cdp_bidi_event :: proc(cl: ^Cdp_Client, wren_name: string, tab: u64, url: string) {
	switch wren_name {
	case "Page.loadEventFired":
		cdp_bidi_emit(cl, "browsingContext.load", fmt.tprintf(`{{"context":"%d","url":%s,"navigation":null,"timestamp":0}}`, tab, remote.quote(url)))
	case "Runtime.consoleAPICalled":
		cdp_bidi_emit(cl, "log.entryAdded", fmt.tprintf(`{{"type":"console","level":"info","text":%s,"source":{{"context":"%d"}},"timestamp":0}}`, remote.quote(url), tab))
	}
}

@(private = "file")
cdp_bidi_emit :: proc(cl: ^Cdp_Client, method, params: string) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"type":"event","method":%s,"params":%s}}`, remote.quote(method), params)
	cdp_frame_text(cl, strings.to_string(b))
}
