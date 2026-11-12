package idl

// The dialect of extension namespaces: what it accepts and refuses, the gate it resolves, and the shape of what is
// generated from it (the host's decoders and tables, the cases, the reference).

import "core:strings"
import "core:testing"
import vmem "core:mem/virtual"

@(private = "file")
EXT_SAMPLE :: `
/// Tabs.
namespace tabs {
  const i64 TAB_ID_NONE = -1;
  enum TabStatus { unloaded, loading, "locked-in" }
  typedef (i64 or i64[]) TabIds;
  struct Tab { i64 id; optional string url; }
  struct CreateProperties { optional string url; [Min=0, Max=9] optional i64 index; bool active; }
  Tab get(i64 tabId);
  Tab update(optional i64 tabId, CreateProperties props);
  void remove(TabIds tabIds);
  [Contexts=(Background, Content)] Tab[] query(optional TabStatus status);
  [Local] string here();
  event onCreated(Tab tab, function done);
}

[Permission=storage, Contexts=(Background, Page, Content)]
namespace storage.local {
  [Host=ext_storage_get] object get(optional string key);
  [Manifest=action, Permission=none] void plain();
}

[Permission=storage, Contexts=(Background, Page)]
namespace storage.session {
  [Host=ext_storage_get] object get(optional string key);
}
`

@(private = "file")
ext_load :: proc(texts: ..string) -> ^Api {
	files := make([dynamic]File_Source, context.temp_allocator)
	for t, i in texts { append(&files, File_Source{name = i == 0 ? "a.widl" : "b.widl", text = t}) }
	return load(files[:])
}

@(private = "file")
ext_expect_error :: proc(t: ^testing.T, want: string, text: string, loc := #caller_location) {
	api := ext_load(text)
	defer destroy(api)
	found := false
	for d in api.diags { if strings.contains(d.msg, want) { found = true } }
	if !found {
		got := strings.builder_make(context.temp_allocator)
		for d in api.diags { strings.write_string(&got, d.msg); strings.write_string(&got, "; ") }
		testing.expectf(t, false, "expected an error containing %q, got: %s", want, strings.to_string(got), loc = loc)
	}
}

@(private = "file")
ext_item :: proc(api: ^Api, ns, name: string) -> ^Ext_Item {
	for n in api.namespaces {
		if n.name != ns { continue }
		for it in n.items { if it.name == name { return it } }
	}
	return nil
}

@(test)
ext_accepts_and_resolves_a_namespace :: proc(t: ^testing.T) {
	api := ext_load(EXT_SAMPLE)
	defer destroy(api)
	testing.expectf(t, len(api.diags) == 0, "no diagnostics: %v", api.diags)
	if len(api.diags) > 0 { return }
	testing.expect_value(t, len(api.namespaces), 3)
	testing.expect_value(t, len(api.modules), 0)
	get := ext_item(api, "tabs", "get")
	testing.expect(t, get.contexts == EXT_DEFAULT_CONTEXTS && get.permission == "" && !get.action, "a namespace without attributes: its pages and its background")
	testing.expect_value(t, get.host_name, "ext_tabs_get")
	testing.expect_value(t, get.odin_name, "Ext_Tabs_Get_Args")
	query := ext_item(api, "tabs", "query")
	testing.expect(t, query.contexts == {.Background, .Content}, "[Contexts] on a member replaces the namespace's")
	testing.expect(t, ext_item(api, "tabs", "here").local && ext_item(api, "tabs", "here").host_name == "", "[Local]: no implementation in the host")
	plain := ext_item(api, "storage.local", "plain")
	testing.expect(t, plain.permission == "" && plain.action && plain.contexts == {.Background, .Popup, .Tab, .Content}, "[Permission=none] and [Manifest=action] on a member")
	lget := ext_item(api, "storage.local", "get")
	sget := ext_item(api, "storage.session", "get")
	testing.expect(t, lget.odin_name == "Ext_Storage_Get_Args" && sget.odin_name == lget.odin_name, "one implementation: one struct of arguments")
	testing.expect(t, sget.contexts == {.Background, .Popup, .Tab}, "Page is Popup and Tab")
	props := api.ext_types["CreateProperties"]
	index_min, _ := props.fields[1].min.?
	index_max, _ := props.fields[1].max.?
	testing.expect(t, index_min == 0 && index_max == 9, "bounds of a field")
	testing.expect(t, ext_json_kinds(Ext_Type{kind = .Union, item = api.ext_types["TabIds"]}) == {.Number, .Array}, "a union takes its members' kinds")
	testing.expect_value(t, ext_snake("getBytesInUse", context.temp_allocator), "get_bytes_in_use")
	testing.expect_value(t, ext_snake("setUninstallURL", context.temp_allocator), "set_uninstall_url")
	testing.expect_value(t, ext_ada("storage.local", context.temp_allocator), "Storage_Local")
	testing.expect_value(t, ext_enum_key("locked-fullscreen"), "LOCKED_FULLSCREEN")
}

@(test)
ext_refuses_bad_namespaces :: proc(t: ^testing.T) {
	ext_expect_error(t, "unknown type Nope", `namespace n { void f(Nope x); }`)
	ext_expect_error(t, "namespace n is declared twice", `namespace n { void f(); } namespace n { void g(); }`)
	ext_expect_error(t, "duplicate type S", `namespace a { struct S { bool b; } } namespace b { struct S { bool b; } }`)
	ext_expect_error(t, "duplicate member n.f", `namespace n { void f(); void f(i64 x); }`)
	ext_expect_error(t, "duplicate parameter x", `namespace n { void f(i64 x, string x); }`)
	ext_expect_error(t, "unknown kind of context Moon", `[Contexts=(Moon)] namespace n { void f(); }`)
	ext_expect_error(t, "only action is known", `[Manifest=icons] namespace n { void f(); }`)
	ext_expect_error(t, "unknown attribute [Fast]", `namespace n { [Fast] void f(); }`)
	ext_expect_error(t, "has the JSON kind of another member", `namespace n { typedef (i64 or f64) N; }`)
	ext_expect_error(t, "a union has two members", `namespace n { typedef (string) S; }`)
	ext_expect_error(t, "bounds a number", `namespace n { void f([Min=0] string s); }`)
	ext_expect_error(t, "[Max] is below [Min]", `namespace n { void f([Min=5, Max=1] i64 x); }`)
	ext_expect_error(t, "only an event's parameter is a function", `namespace n { void f(function cb); }`)
	ext_expect_error(t, "with different parameters", `namespace n { [Host=h] void f(i64 x); [Host=h] void g(string x); }`)
	ext_expect_error(t, "mark it [Local]", `namespace n { attribute string id; }`)
	ext_expect_error(t, "is not a i64", `namespace n { const i64 N = "x"; }`)
	ext_expect_error(t, "enum E: duplicate value", `namespace n { enum E { a, a } }`)
	ext_expect_error(t, "struct S has no fields", `namespace n { struct S { } }`)
	ext_expect_error(t, "would both be generated as Ext_N_A_Args", `namespace n { struct AArgs { bool b; } [Host=ext_n_a] void f(i64 x); [Host=ext_n_a_args] void g(i64 y); }`)
}

@(test)
ext_generates_decoders_tables_cases_and_docs :: proc(t: ^testing.T) {
	a := ext_load(EXT_SAMPLE)
	defer destroy(a)
	b := ext_load(EXT_SAMPLE)
	defer destroy(b)
	testing.expect(t, len(a.diags) == 0 && len(b.diags) == 0, "valid")
	if len(a.diags) > 0 { return }
	out: vmem.Arena
	defer vmem.arena_destroy(&out)
	context.allocator = vmem.arena_allocator(&out)
	host := emit_ext_host(a, "page")
	testing.expect(t, host == emit_ext_host(b, "page"), "the host output is stable")
	cases := emit_ext_cases(a, "page")
	testing.expect(t, cases == emit_ext_cases(b, "page"), "the cases are stable")

	// types and the struct of arguments
	testing.expect(t, strings.contains(host, "Ext_Tabs_Create_Properties :: struct {\n\turl: Maybe(string),\n\tindex: Maybe(i64),\n\tactive: bool,\n}"), "a struct: optional fields are Maybe")
	testing.expect(t, strings.contains(host, "Ext_Tabs_Tab_Ids :: union {i64, []i64}"), "a typedef union is an Odin union")
	testing.expect(t, strings.contains(host, "Ext_Tabs_Update_Args :: struct {\n\ttab_id: Maybe(i64),\n\tprops: Ext_Tabs_Create_Properties,\n}"), "the struct of arguments")
	testing.expect(t, strings.count(host, "Ext_Storage_Get_Args :: struct") == 1, "a shared implementation's struct is written once")
	// the decoders
	testing.expect(t, strings.contains(host, "ext_dec_int_in(f, 0, 9, &x, err)"), "a field's bounds")
	testing.expect(t, strings.contains(host, "return ext_missing_property(err, \"active\")"), "a required property")
	testing.expect(t, strings.contains(host, "case .Array:\n\t\tx: []i64\n\t\tif !ext_dec_list(v, &x, ext_dec_int, err)"), "a union member decodes by the value's kind")
	testing.expect(t, strings.contains(host, "EXT_SPEC_TABS_UPDATE := [?]Ext_Param_Spec{{kinds = {.Number}, optional = true}, {kinds = {.Object}, optional = false}}"), "the matcher's signature")
	testing.expect(t, strings.contains(host, "return ext_signature_error(\"tabs.update(optional integer tabId, object props)\")"), "Chrome's form of the signature")
	testing.expect(t, strings.contains(host, "\text_tabs_get(x, a)\n"), "the trampoline calls the implementation with its arguments")
	testing.expect(t, strings.contains(host, "// ext_tabs_get :: proc(x: ^Ext_Call, a: Ext_Tabs_Get_Args)"), "the expected prototype is written")
	// the tables
	testing.expect(t, strings.contains(host, "{name = \"tabs.query\", contexts = {.Background, .Content}, invoke = ext_invoke_tabs_query, check = ext_check_tabs_query},"), "a routed method")
	testing.expect(t, strings.contains(host, "{name = \"storage.local.plain\", contexts = {.Background, .Popup, .Tab, .Content}, action = true, invoke"), "a member's gate")
	testing.expect(t, strings.contains(host, "{name = \"storage.session.get\", permission = \"storage\", contexts = {.Background, .Popup, .Tab}, invoke"), "a namespace's permission")
	testing.expect(t, strings.contains(host, "EXT_LOCALS := [?]Ext_Member{\n\t{name = \"tabs.here\""), "a [Local] member is listed, not routed")
	testing.expect(t, strings.contains(host, "{name = \"tabs.onCreated\", contexts = {.Background, .Popup, .Tab}},"), "an event")
	testing.expect(t, strings.contains(host, "{name = \"tabs\", constants = `{\"TAB_ID_NONE\":-1,\"TabStatus\":{\"UNLOADED\":\"unloaded\",\"LOADING\":\"loading\",\"LOCKED_IN\":\"locked-in\"}}`},"), "the constants of chrome.tabs")
	testing.expect(t, !strings.contains(host, "here ::"), "no trampoline for a [Local] member")

	// the cases
	testing.expect(t, strings.contains(cases, "{name = \"tabs.get\", args = `[1]`, want = .Decodes"), "the required arguments decode")
	testing.expect(t, strings.contains(cases, "{name = \"tabs.get\", args = `[]`, want = .Refused, what = \"tabId missing\"}"), "a missing argument")
	testing.expect(t, strings.contains(cases, "{name = \"tabs.get\", args = `[true]`, want = .Refused, what = \"tabId of a wrong type\"}"), "a wrong type")
	testing.expect(t, strings.contains(cases, "what = \"props.index below [Min]\""), "a field's bound")
	testing.expect(t, strings.contains(cases, "what = \"props.active missing\""), "a required property")
	testing.expect(t, strings.contains(cases, "{table = .Method, name = \"storage.local.get\", kind = .Background, action = true, want = .Denied, what = \"without the permission storage\"}"), "a missing permission")
	testing.expect(t, strings.contains(cases, "{table = .Method, name = \"storage.session.get\", kind = .Content, permission = \"storage\", action = true, want = .Denied, what = \"in a Content context\"}"), "a wrong context")
	testing.expect(t, strings.contains(cases, "what = \"without an action in the manifest\""), "a missing action")
	testing.expect(t, strings.contains(cases, "{table = .Event, name = \"tabs.onCreated\""), "events have gate cases")
	testing.expect(t, strings.contains(cases, "{table = .Local, name = \"tabs.here\""), "local members have gate cases")
	testing.expect(t, strings.contains(cases, "{name = \"tabs.query\", args = `[]`, want = .Decodes, what = \"the required arguments\"}"), "no argument: the optional ones left out")
	testing.expect(t, strings.contains(cases, "{name = \"tabs.update\", args = `[true,{\"active\":true}]`, want = .Refused, what = \"tabId of a wrong type\"}"), "a wrong type in an optional parameter's place")

	// the reference
	docs := emit_ext_docs(a)
	testing.expect_value(t, len(docs), 4)   // the index and one page per namespace
	testing.expect(t, strings.contains(docs[0].text, "| [tabs](tabs.md) | no permission; contexts: Background, Popup, Tab | 5 | 1 |"), "the index")
	testing.expect(t, strings.contains(docs[1].text, "| `here()` | string | realm |"), "a local member's status")
}
