package page

// Phase 3's methods against their description (api/ext_scripting.widl, ext_webnavigation.widl, ext_tabs.widl): the
// arguments Bitwarden sends decode, wrong ones are refused, and a content script gets none of them.

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "wb:extensions"

@(test)
ext_scripting_arguments_and_gate :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	decode :: proc(name, args: string) -> string {
		v, _ := json.parse_string(args, .JSON, false, context.temp_allocator)
		list, _ := v.(json.Array)
		m := ext_method_find(name)
		if m == nil { return "absent" }
		return m.check(list)
	}
	// what Bitwarden's background sends (apps/browser/src/platform/browser/browser-api.ts)
	testing.expect_value(t, decode("scripting.executeScript", `[{"target":{"tabId":3,"frameIds":[0]},"files":["content/bootstrap-autofill.js"],"injectImmediately":true}]`), "")
	testing.expect_value(t, decode("scripting.executeScript", `[{"target":{"tabId":3,"allFrames":true},"func":"() => 1","args":[1,"a",{"b":null}],"world":"MAIN"}]`), "")
	testing.expect(t, strings.has_prefix(decode("scripting.executeScript", `[{"target":{"tabId":3},"files":["a.js"],"world":"ELSEWHERE"}]`), "Error in invocation of scripting.executeScript"), "an unknown world")
	testing.expect(t, decode("scripting.executeScript", `[{"files":["a.js"]}]`) != "", "a target is required")
	testing.expect_value(t, decode("scripting.insertCSS", `[{"target":{"tabId":3},"css":"a{color:red}","origin":"USER"}]`), "")
	testing.expect_value(t, decode("scripting.removeCSS", `[{"target":{"tabId":3},"files":["content/autofill.css"]}]`), "")
	testing.expect_value(t, decode("scripting.registerContentScripts", `[[{"id":"x","matches":["https://*/*"],"js":["a.js"],"runAt":"document_end","allFrames":true}]]`), "")
	testing.expect(t, decode("scripting.registerContentScripts", `[[{"id":"x","runAt":"later"}]]`) != "", "run_at is one of three")
	testing.expect_value(t, decode("scripting.unregisterContentScripts", `[]`), "")
	testing.expect_value(t, decode("scripting.getRegisteredContentScripts", `[{"ids":["x"]}]`), "")
	testing.expect_value(t, decode("tabs.sendMessage", `[3,{"command":"collectPageDetails"}]`), "")
	testing.expect_value(t, decode("tabs.sendMessage", `[3,"text",{"frameId":0}]`), "")
	testing.expect(t, decode("tabs.sendMessage", `["3","text"]`) != "", "a tab id is a number")
	testing.expect_value(t, decode("webNavigation.getFrame", `[{"tabId":3,"frameId":0}]`), "")
	testing.expect_value(t, decode("webNavigation.getAllFrames", `[{"tabId":3}]`), "")

	im: extensions.Image
	perms := [?]string{"scripting", "webNavigation", "storage", "tabs"}
	im.manifest.permissions = perms[:]
	names :: proc(text: string) -> map[string]bool {
		v, _ := json.parse_string(text, .JSON, false, context.temp_allocator)
		o, _ := v.(json.Object)
		out := make(map[string]bool, context.temp_allocator)
		keys := [?]string{"methods", "events", "local"}
		for key in keys {
			list, _ := o[key].(json.Array)
			for x in list { if s, ok := x.(json.String); ok { out[s] = true } }
		}
		return out
	}
	bg := names(ext_info_json(&im, .Background))
	bg_has := [?]string{"scripting.executeScript", "scripting.insertCSS", "scripting.registerContentScripts", "tabs.sendMessage", "tabs.connect", "webNavigation.getAllFrames", "webNavigation.onCompleted"}
	for want in bg_has { testing.expectf(t, bg[want], "the background has %s", want) }
	content := names(ext_info_json(&im, .Content))
	content_lacks := [?]string{"scripting.executeScript", "tabs.sendMessage", "tabs.connect", "webNavigation.getFrame", "webNavigation.onCommitted"}
	for not_want in content_lacks { testing.expectf(t, !content[not_want], "a content script has no %s", not_want) }
	testing.expect(t, content["runtime.sendMessage"] && content["runtime.connect"], "a content script has its messages and ports")
	bare: extensions.Image
	none := names(ext_info_json(&bare, .Background))
	testing.expect(t, !none["scripting.executeScript"] && !none["webNavigation.getFrame"], "scripting and webNavigation need their permission")
	testing.expect(t, none["tabs.sendMessage"], "tabs.sendMessage needs none")
}
