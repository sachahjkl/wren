package browser

// CDP targets, the /json HTTP endpoints, the DevToolsActivePort file, and the translation of Wren's events to CDP
// events. A Wren tab is a CDP "target" of type "page"; its id as a decimal string is the CDP targetId and the
// WebSocket path /devtools/page/<id> (a tool connects there; this adapter serves one WebSocket for the whole browser,
// and the target a message is about is carried in its params, so the path's id is informational).

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "wb:remote"

////////////////////////////////
// /json endpoints

@(private)
cdp_ws_base :: proc() -> string { return fmt.tprintf("ws://127.0.0.1:%d", the_cdp.port) }

@(private)
cdp_version_json :: proc(app: ^App) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"Browser":"Wren/%s","Protocol-Version":"1.3","User-Agent":%s,"V8-Version":"0","WebKit-Version":"0","webSocketDebuggerUrl":"%s/devtools/browser"}}`,
		APP_VERSION, remote.quote(fmt.tprintf("Wren/%s", APP_VERSION)), cdp_ws_base())
	return strings.to_string(b)
}

@(private)
cdp_version_result :: proc(app: ^App) -> string {
	return fmt.tprintf(`{{"protocolVersion":"1.3","product":"Wren/%s","revision":%s,"userAgent":%s,"jsVersion":"0"}}`,
		APP_VERSION, remote.quote(app_commit()), remote.quote(fmt.tprintf("Wren/%s", APP_VERSION)))
}

@(private)
cdp_list_json :: proc(app: ^App) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	for t in tabs_all(app) {
		if t.frame != nil { continue }   // only top-level tabs are targets
		if !first { strings.write_byte(&b, ',') }
		first = false
		cdp_target_entry(&b, app, t)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(private = "file")
cdp_target_entry :: proc(b: ^strings.Builder, app: ^App, t: ^Tab) {
	id := fmt.tprintf("%d", t.id)
	fmt.sbprintf(b, `{{"id":"%s","type":"page","title":%s,"url":%s,"webSocketDebuggerUrl":"%s/devtools/page/%s","devtoolsFrontendUrl":""}}`,
		id, remote.quote(t.title), remote.quote(t.url), cdp_ws_base(), id)
}

@(private)
cdp_new_target :: proc(app: ^App, url: string) -> string {
	t := tab_open(app, url, origin = .User)
	b := strings.builder_make(context.temp_allocator)
	cdp_target_entry(&b, app, t)
	return strings.to_string(b)
}

@(private)
cdp_close_target :: proc(app: ^App, id: string) {
	if n, ok := strconv.parse_u64(id); ok { if t := tab_by_id(app, n); t != nil { tab_close_tab(app, t) } }
}

@(private)
cdp_activate_target :: proc(app: ^App, id: string) {
	if n, ok := strconv.parse_u64(id); ok { if t := tab_by_id(app, n); t != nil { tab_reveal(app, t) } }
}

////////////////////////////////
// Target.* answered in the adapter (envelope only)

@(private)
cdp_attach :: proc(app: ^App, cl: ^Cdp_Client, id_text: string, params: json_obj) {
	target, _ := remote.param_string(params, "targetId")
	// a flat session id: the target's id (CDP's sessionId is opaque; we reuse the target id)
	delete(cl.session)
	cl.session = strings.clone(target)
	cdp_send_result(cl, id_text, fmt.tprintf(`{{"sessionId":%s}}`, remote.quote(target)))
}

@(private)
cdp_target_info :: proc(app: ^App, cl: ^Cdp_Client, id_text: string, params: json_obj) {
	target, _ := remote.param_string(params, "targetId")
	n, _ := strconv.parse_u64(target)
	t := tab_by_id(app, n)
	if t == nil { t = current_tab(app) }
	if t == nil { cdp_send_error(cl, id_text, -32000, "no target", false); return }
	cdp_send_result(cl, id_text, fmt.tprintf(`{{"targetInfo":%s}}`, cdp_target_info_object(t)))
}

@(private)
cdp_target_info_object :: proc(t: ^Tab) -> string {
	return fmt.tprintf(`{{"targetId":"%d","type":"page","title":%s,"url":%s,"attached":true,"browserContextId":"default"}}`,
		t.id, remote.quote(t.title), remote.quote(t.url))
}

// Target.getTargets: reshape Wren's {targetInfos:[{targetId:<int>,...}]} into CDP's string-id form.
@(private)
cdp_targets_result :: proc(app: ^App, wren_result: json_obj) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"targetInfos":[`)
	first := true
	for t in tabs_all(app) {
		if t.frame != nil { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		strings.write_string(&b, cdp_target_info_object(t))
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

////////////////////////////////
// Events: Wren's events (remote_event) to the connected CDP / BiDi clients.

// Called for each CDP / BiDi subscriber when a Wren event fires (remote_shell.odin remote_event). `name` is the Wren
// event name, `params` its JSON.
cdp_on_wren_event :: proc(conn: u64, name, params_json: string) {
	c := &the_cdp
	cl := c.clients[conn & ~CDP_CONN_TAG]
	if cl == nil || !cl.upgraded { return }
	params: json_obj
	if root, err := json_parse(params_json); err { params, _ = root.(json_obj) }
	tab, _ := remote.param_int(params, "tabId")
	url, _ := remote.param_string(params, "url")
	if cl.flavor == .Bidi {
		cdp_bidi_event(cl, name, u64(tab), url)
		return
	}
	switch name {
	case "Page.loadEventFired":
		cdp_emit(cl, "Page.loadEventFired", fmt.tprintf(`{{"timestamp":0}}`))
		cdp_emit(cl, "Page.frameNavigated", fmt.tprintf(`{{"frame":{{"id":"%d","url":%s,"loaderId":"0","securityOrigin":"","mimeType":"text/html"}}}}`, tab, remote.quote(url)))
		cdp_emit(cl, "Page.lifecycleEvent", fmt.tprintf(`{{"frameId":"%d","loaderId":"0","name":"load","timestamp":0}}`, tab))
	case "Runtime.consoleAPICalled":
		kind, _ := remote.param_string(params, "type")
		text, _ := remote.param_string(params, "text")
		cdp_emit(cl, "Runtime.consoleAPICalled", fmt.tprintf(`{{"type":%s,"args":[{{"type":"string","value":%s}}],"executionContextId":1,"timestamp":0}}`,
			remote.quote(kind == "" ? "log" : kind), remote.quote(text)))
	}
}

// A CDP event frame to one client (no sessionId: the flat session CDP tools accept for a single page).
@(private)
cdp_emit :: proc(cl: ^Cdp_Client, method, params: string) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"method":%s,"params":%s}}`, remote.quote(method), params == "" ? "{}" : params)
	cdp_frame_text(cl, strings.to_string(b))
}

////////////////////////////////
// DevToolsActivePort: the file a tool reads to find the browser endpoint (Chrome writes it in the profile).

@(private)
cdp_write_active_port :: proc(app: ^App) {
	path := strings.concatenate({app.profile_dir, "/DevToolsActivePort"}, context.temp_allocator)
	body := fmt.tprintf("%d\n/devtools/browser\n", the_cdp.port)
	_ = os.write_entire_file(path, transmute([]byte)body)
}

@(private)
cdp_remove_active_port :: proc(app: ^App) {
	path := strings.concatenate({app.profile_dir, "/DevToolsActivePort"}, context.temp_allocator)
	_ = os.remove(path)
}
