package page

// The extension API's description against its use: the generated conformance cases (ext_api_generated_test.odin, from
// api/ext_*.widl) through the generated decoders and the gate, and the lists a context gets (Ext_info) for the rules
// phases 1 and 2 kept in a hand table before the description existed.

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "wb:extensions"

Ext_Case_Table :: enum u8 { Method, Event, Local }
Ext_Case_Want :: enum u8 { Decodes, Refused, Allowed, Denied }

// One generated case: a call's arguments (Decodes, Refused), or a member in a context with a manifest (Allowed, Denied).
Ext_Case :: struct {
	table:      Ext_Case_Table,
	name:       string,
	args:       string,          // a JSON list
	kind:       Ext_Kind,
	permission: string,          // the manifest's only permission ("" : none)
	action:     bool,            // the manifest has an action
	want:       Ext_Case_Want,
	what:       string,
}

@(private = "file")
ext_gate_of :: proc(table: Ext_Case_Table, name: string) -> (contexts: Ext_Contexts, permission: string, action: bool, found: bool) {
	switch table {
	case .Method:
		if m := ext_method_find(name); m != nil { return m.contexts, m.permission, m.action, true }
	case .Event:
		for m in EXT_EVENTS { if m.name == name { return m.contexts, m.permission, m.action, true } }
	case .Local:
		for m in EXT_LOCALS { if m.name == name { return m.contexts, m.permission, m.action, true } }
	}
	return {}, "", false, false
}

@(test)
ext_api_conformance_cases :: proc(t: ^testing.T) {
	testing.expect(t, len(EXT_CASES) > 0, "the description makes cases")
	for c in EXT_CASES {
		defer free_all(context.temp_allocator)
		switch c.want {
		case .Decodes, .Refused:
			m := ext_method_find(c.name)
			if m == nil { testing.expectf(t, false, "%s is not in EXT_METHODS", c.name); continue }
			v, err := json.parse_string(c.args, .JSON, false, context.temp_allocator)
			args, ok := v.(json.Array)
			if err != .None || !ok { testing.expectf(t, false, "%s: the case's arguments %s are not a JSON list", c.name, c.args); continue }
			message := m.check(args)
			got := message == "" ? Ext_Case_Want.Decodes : Ext_Case_Want.Refused
			testing.expectf(t, got == c.want, "%s %s (%s): %v, %q", c.name, c.args, c.what, got, message)
			if got == .Refused { testing.expectf(t, strings.has_prefix(message, "Error in invocation of "), "%s (%s): the error names the call: %q", c.name, c.what, message) }
		case .Allowed, .Denied:
			contexts, permission, action, found := ext_gate_of(c.table, c.name)
			if !found { testing.expectf(t, false, "%s is not in its table (%v)", c.name, c.table); continue }
			im: extensions.Image
			perms := [1]string{c.permission}
			if c.permission != "" { im.manifest.permissions = perms[:] }
			im.manifest.has_action = c.action
			got := ext_allowed(&im, c.kind, contexts, permission, action) ? Ext_Case_Want.Allowed : Ext_Case_Want.Denied
			testing.expectf(t, got == c.want, "%s (%s): %v", c.name, c.what, got)
		}
	}
}

// What each kind of context lists: the rules of the hand table phases 1 and 2 had (a content script: messages, ports,
// storage but session, i18n; an offscreen document: runtime only; the rest: everything its manifest allows).
@(test)
ext_api_info_lists_what_a_context_may_use :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	im: extensions.Image
	perms := [?]string{"storage", "alarms", "idle", "offscreen"}
	im.manifest.permissions = perms[:]
	im.manifest.has_action = true
	parse :: proc(text: string) -> json.Object {
		v, _ := json.parse_string(text, .JSON, false, context.temp_allocator)
		o, _ := v.(json.Object)
		return o
	}
	names :: proc(o: json.Object) -> map[string]bool {
		out := make(map[string]bool, context.temp_allocator)
		keys := [?]string{"methods", "events", "local"}
		for key in keys {
			list, _ := o[key].(json.Array)
			for v in list { if s, ok := v.(json.String); ok { out[s] = true } }
		}
		return out
	}

	content := names(parse(ext_info_json(&im, .Content)))
	content_has := [?]string{"runtime.sendMessage", "runtime.onMessage", "runtime.onConnect", "runtime.connect", "runtime.getURL", "runtime.id", "storage.local.get", "storage.sync.set", "storage.managed.get", "storage.onChanged", "i18n.getMessage"}
	for want in content_has {
		testing.expectf(t, content[want], "a content script has %s", want)
	}
	content_lacks := [?]string{"storage.session.get", "tabs.query", "runtime.getPlatformInfo", "extension.getViews", "alarms.create", "action.setTitle"}
	for not_want in content_lacks {
		testing.expectf(t, !content[not_want], "a content script has no %s", not_want)
	}

	offscreen := names(parse(ext_info_json(&im, .Offscreen)))
	for n in offscreen { testing.expectf(t, strings.has_prefix(n, "runtime."), "an offscreen document has runtime only, not %s", n) }
	testing.expect(t, offscreen["runtime.sendMessage"] && offscreen["runtime.onInstalled"], "an offscreen document has runtime")

	bg_info := parse(ext_info_json(&im, .Background))
	bg := names(bg_info)
	bg_has := [?]string{"tabs.query", "windows.create", "storage.session.get", "alarms.create", "idle.queryState", "offscreen.createDocument", "action.setBadgeText", "action.onClicked", "permissions.contains", "management.getSelf", "extension.getViews", "runtime.reload"}
	for want in bg_has {
		testing.expectf(t, bg[want], "the background has %s", want)
	}
	constants, _ := bg_info["constants"].(json.Object)
	tabs, _ := constants["tabs"].(json.Object)
	status, _ := tabs["TabStatus"].(json.Object)
	complete, _ := status["COMPLETE"].(json.String)
	testing.expect(t, complete == "complete", "chrome.tabs.TabStatus.COMPLETE")
	sync, _ := constants["storage.sync"].(json.Object)
	quota, _ := sync["QUOTA_BYTES"].(json.Float)
	testing.expect(t, quota == 102400, "chrome.storage.sync.QUOTA_BYTES")

	// a permission or an action the manifest lacks takes the namespace away
	bare: extensions.Image
	none := names(parse(ext_info_json(&bare, .Background)))
	bare_lacks := [?]string{"storage.local.get", "alarms.create", "idle.queryState", "offscreen.hasDocument", "action.setTitle", "action.onClicked"}
	for not_want in bare_lacks {
		testing.expectf(t, !none[not_want], "without its permission or an action, no %s", not_want)
	}
	testing.expect(t, none["tabs.query"] && none["runtime.sendMessage"], "what needs no permission stays")
}

// The matcher and the decoders on the calls of phases 1 and 2 whose arguments move (Chrome's optional leading
// parameters), and the errors a caller reads.
@(test)
ext_api_arguments_match_their_signature :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	decode :: proc(name, args: string) -> string {
		v, _ := json.parse_string(args, .JSON, false, context.temp_allocator)
		list, _ := v.(json.Array)
		m := ext_method_find(name)
		if m == nil { return "absent" }
		return m.check(list)
	}
	{
		a: Ext_Alarms_Create_Args
		v, _ := json.parse_string(`[{"delayInMinutes":1}]`, .JSON, false, context.temp_allocator)
		testing.expect_value(t, ext_decode_alarms_create(v.(json.Array), &a), "")
		_, has_name := a.name.?
		info, has_info := a.alarm_info.?
		delay, _ := info.delay_in_minutes.?
		testing.expect(t, !has_name && has_info && delay == 1, "alarms.create(info): the name is left out")
	}
	{
		a: Ext_Tabs_Update_Args
		v, _ := json.parse_string(`[{"url":"https://a.test/"}]`, .JSON, false, context.temp_allocator)
		testing.expect_value(t, ext_decode_tabs_update(v.(json.Array), &a), "")
		_, has_tab := a.tab_id.?
		testing.expect(t, !has_tab && (a.update_properties.url.? or_else "") == "https://a.test/", "tabs.update(props): the tab is left out")
	}
	{
		a: Ext_Runtime_Send_Message_Args
		v, _ := json.parse_string(`["hello"]`, .JSON, false, context.temp_allocator)
		testing.expect_value(t, ext_decode_runtime_send_message(v.(json.Array), &a), "")
		_, has_id := a.extension_id.?
		message, _ := a.message.(json.String)
		testing.expect(t, !has_id && message == "hello", "sendMessage(text): the text is the message, not an extension id")
	}
	{
		a: Ext_Storage_Get_Args
		v, _ := json.parse_string(`[["a","b"]]`, .JSON, false, context.temp_allocator)
		testing.expect_value(t, ext_decode_storage_local_get(v.(json.Array), &a), "")
		keys, is_list := a.keys.([]string)
		testing.expect(t, is_list && len(keys) == 2 && keys[1] == "b", "a union takes the member of the value's kind")
	}
	testing.expect_value(t, decode("storage.local.get", `[null]`), "")
	testing.expect_value(t, decode("tabs.get", `["7"]`), "Error in invocation of tabs.get(integer tabId): No matching signature.")
	testing.expect_value(t, decode("tabs.create", `[{"url":7}]`), "Error in invocation of tabs.create(object createProperties): Error at parameter 'createProperties': Error at property 'url': Invalid type: expected string, found integer.")
	testing.expect_value(t, decode("windows.create", `[{"type":"tall"}]`), `Error in invocation of windows.create(optional object createData): Error at parameter 'createData': Error at property 'type': Value must be one of "normal", "popup", "panel".`)
	testing.expect_value(t, decode("idle.setDetectionInterval", `[-1]`), "Error in invocation of idle.setDetectionInterval(integer intervalInSeconds): Error at parameter 'intervalInSeconds': Value must be at least 0.")
	testing.expect_value(t, decode("offscreen.createDocument", `[{"url":"o.html","reasons":["NOPE"],"justification":"x"}]`) != "", true)
	testing.expect_value(t, decode("runtime.getPlatformInfo", `[]`), "")
	testing.expect_value(t, decode("runtime.getPlatformInfo", `[1]`), "Error in invocation of runtime.getPlatformInfo(): No matching signature.")
}
