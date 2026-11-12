package extensions

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"

////////////////////////////////
// ids

@(test)
test_id_encoding :: proc(t: ^testing.T) {
	// SHA-256 of nothing: e3b0c442 98fc1c14 9afbf4c8 996fb924..., each nibble a letter 'a' + n
	id := id_from_bytes(nil, context.temp_allocator)
	testing.expect_value(t, id, "odlameecjipmbmbejkplpemijjgpljce")
	testing.expect(t, id_valid(id))
	testing.expect(t, !id_valid("odlameecjipmbmbejkplpemijjgpljcz"))
	testing.expect(t, !id_valid("short"))
}

@(test)
test_id_from_path_and_key :: proc(t: ^testing.T) {
	a := id_from_path("/home/user/ext", context.temp_allocator)
	b := id_from_path("/home/user/ext2", context.temp_allocator)
	testing.expect(t, id_valid(a) && id_valid(b))
	testing.expect(t, a != b)
	testing.expect_value(t, a, id_from_path("/home/user/ext", context.temp_allocator))
	// a key is the base64 of a DER public key: the id is its hash (any bytes give an id; not base64 gives none)
	k, ok := id_from_key("AAECAwQFBgcICQ==", context.temp_allocator)
	testing.expect(t, ok && id_valid(k))
	testing.expect_value(t, k, id_from_bytes([]byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}, context.temp_allocator))
	_, bad := id_from_key("not base64 !!", context.temp_allocator)
	testing.expect(t, !bad)
}

////////////////////////////////
// the catalogue

@(test)
test_catalogue_messages :: proc(t: ^testing.T) {
	arena: base.Arena
	_ = base.arena_init_growing(&arena)
	defer base.arena_destroy(&arena)
	a := base.arena_allocator(&arena)
	c: Catalogue
	c.messages = make(map[string]Message, 4, a)
	c.fallback = make(map[string]Message, 4, a)
	c.locale = "fr"
	testing.expect(t, catalogue_parse(`{
	  // comments are allowed
	  "Greeting": {"message": "Bonjour $Who$ et $other$ ($$5)", "placeholders": {"who": {"content": "$1"}, "OTHER": {"content": "<$2>"}}},
	  "plain": {"message": "a $1 b $3 c"}
	}`, &c.messages, a))
	testing.expect(t, catalogue_parse(`{"onlyEnglish": {"message": "English"}, "plain": {"message": "not this"}}`, &c.fallback, a))
	m, ok := catalogue_get(&c, "greeting", {"Ann", "Bob"})
	testing.expect(t, ok)
	testing.expect_value(t, m, "Bonjour Ann et <Bob> ($5)")
	m, ok = catalogue_get(&c, "PLAIN", {"x"})
	testing.expect_value(t, m, "a x b  c")
	m, ok = catalogue_get(&c, "onlyEnglish", nil)
	testing.expect(t, ok)
	testing.expect_value(t, m, "English")   // (the fallback: default_locale)
	_, ok = catalogue_get(&c, "absent", nil)
	testing.expect(t, !ok)
	m, _ = catalogue_get(&c, "@@extension_id", nil, "abc")
	testing.expect_value(t, m, "abc")
	m, _ = catalogue_get(&c, "@@ui_locale", nil)
	testing.expect_value(t, m, "fr")
	testing.expect(t, !catalogue_parse("[1]", &c.messages, a))
}

@(test)
test_manifest_localize :: proc(t: ^testing.T) {
	arena: base.Arena
	_ = base.arena_init_growing(&arena)
	defer base.arena_destroy(&arena)
	a := base.arena_allocator(&arena)
	c: Catalogue
	c.messages = make(map[string]Message, 4, a)
	_ = catalogue_parse(`{"extName": {"message": "Say \"hi\"\\"}}`, &c.messages, a)
	out := manifest_localize(`{"name": "__MSG_extName__", "d": "__MSG_absent__"}`, &c, "id")
	testing.expect_value(t, out, `{"name": "Say \"hi\"\\", "d": ""}`)
	testing.expect_value(t, json_strip_comments(`{"a": "//x" /* c */, // d` + "\n" + `"b": 1}`), `{"a": "//x"  , ` + "\n" + `"b": 1}`)
}

@(test)
test_locale_candidates :: proc(t: ^testing.T) {
	l := locale_candidates("en-US", "en")
	testing.expect_value(t, len(l), 3)
	testing.expect_value(t, l[0], "en_US")
	testing.expect_value(t, l[1], "en")
	testing.expect_value(t, l[2], "en")
}

////////////////////////////////
// paths and packages

@(test)
test_package_path_normalize :: proc(t: ^testing.T) {
	Case :: struct { in_, out: string, ok: bool }
	cases := [?]Case{
		{"popup/index.html", "popup/index.html", true},
		{"/popup/index.html", "popup/index.html", true},
		{"./popup//./index.html", "popup/index.html", true},
		{"a/b/../c.js", "a/c.js", true},
		{"../outside.js", "", false},
		{"a/../../outside.js", "", false},
		{"//evil.com/x", "", false},
		{"C:/Windows/x", "", false},
		{"a\\b.js", "", false},
		{"a\x00b", "", false},
		{"", "", true},
	}
	for c in cases {
		got, ok := package_path_normalize(c.in_, context.temp_allocator)
		testing.expectf(t, ok == c.ok && (!ok || got == c.out), "%q: %q %v, expected %q %v", c.in_, got, ok, c.out, c.ok)
	}
}

@(private = "file")
temp_package :: proc(name: string) -> string {
	root := fmt.tprintf("%s/wren_ext_test_%s_%d", os.temp_directory(context.temp_allocator) or_else ".", name, os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(strings.concatenate({root, "/sub"}, context.temp_allocator))
	return root
}

@(private = "file")
put :: proc(root, rel, text: string) {
	_ = os.write_entire_file(strings.concatenate({root, "/", rel}, context.temp_allocator), transmute([]byte)text)
}

@(test)
test_package_index_and_limits :: proc(t: ^testing.T) {
	root := temp_package("index")
	defer { _ = os.remove_all(root) }
	put(root, "manifest.json", "{}")
	put(root, "sub/a.js", "12345")
	put(root, "sub/b.js", "12345")
	s := settings_default()
	files := make(map[string]File_Entry, 8, context.temp_allocator)
	testing.expect_value(t, package_index_dir(root, &s, &files, context.temp_allocator), Package_Error.None)
	testing.expect_value(t, len(files), 3)
	testing.expect(t, "sub/a.js" in files)
	data, ok := package_read(root, &files, "sub/a.js", 100, context.temp_allocator)
	testing.expect(t, ok && string(data) == "12345")
	_, absent := package_read(root, &files, "sub/c.js", 100, context.temp_allocator)
	testing.expect(t, !absent)   // (a file not in the index is never read, even if it appears later)

	s.package_max_files = 2
	few := make(map[string]File_Entry, 8, context.temp_allocator)
	testing.expect_value(t, package_index_dir(root, &s, &few, context.temp_allocator), Package_Error.Too_Many_Files)
	s = settings_default()
	s.package_max_bytes = 8
	small := make(map[string]File_Entry, 8, context.temp_allocator)
	testing.expect_value(t, package_index_dir(root, &s, &small, context.temp_allocator), Package_Error.Too_Large)
	none := make(map[string]File_Entry, 8, context.temp_allocator)
	testing.expect_value(t, package_index_dir(strings.concatenate({root, "/absent"}, context.temp_allocator), &s, &none, context.temp_allocator), Package_Error.Not_Found)
}

// The fixture extension loads as a whole: id from its path, catalogue, localized manifest, background script.
@(test)
test_image_load_fixture :: proc(t: ^testing.T) {
	r := image_load("examples/extensions/hello", settings_default(), "en-US", "")
	defer load_result_destroy(&r)
	if !testing.expectf(t, r.image != nil && r.image.ok, "the fixture must load: %s", r.error) { return }
	im := r.image
	testing.expect(t, id_valid(im.id))
	testing.expect_value(t, im.id, id_from_path(r.path, context.temp_allocator))
	testing.expect_value(t, im.manifest.name, "Hello extension")
	testing.expect_value(t, im.manifest.action.popup, "popup.html")
	testing.expect(t, len(im.background_source) > 0)
	testing.expect_value(t, im.page_csp, "script-src 'self'; object-src 'self'")
	msg, ok := catalogue_get(&im.catalogue, "greeting", {"you"})
	testing.expect(t, ok)
	testing.expect_value(t, msg, "Hello you!")
	testing.expect(t, strings.contains(im.manifest.text, "\"Hello extension\""))   // (getManifest gives the messages put in)
}

@(test)
test_image_load_errors :: proc(t: ^testing.T) {
	root := temp_package("errors")
	defer { _ = os.remove_all(root) }
	r := image_load(root, settings_default(), "en-US", "")
	testing.expect(t, r.error != "")   // no manifest.json
	load_result_destroy(&r)
	put(root, "manifest.json", `{"manifest_version": 3, "name": "__MSG_n__", "version": "1", "default_locale": "en"}`)
	r2 := image_load(root, settings_default(), "en-US", "")
	testing.expect(t, r2.image != nil && !r2.image.ok)   // default_locale without _locales
	testing.expect(t, strings.contains(r2.error, "_locales/en/messages.json"))
	load_result_destroy(&r2)
}

////////////////////////////////
// storage areas

@(test)
test_area_quota_and_changes :: proc(t: ^testing.T) {
	a: Area
	defer area_destroy(&a)
	a.max_bytes = 20
	ch, err := area_set(&a, {"k"}, {`"value"`})
	testing.expect_value(t, err, Area_Error.None)
	testing.expect_value(t, len(ch), 1)
	testing.expect(t, ch[0].has && !ch[0].had)
	testing.expect_value(t, a.bytes, 1 + 7)
	ch, err = area_set(&a, {"k"}, {`"value"`})
	testing.expect_value(t, len(ch), 0)   // (the same value: no change, no event)
	_, err = area_set(&a, {"big"}, {`"0123456789abcdef"`})
	testing.expect_value(t, err, Area_Error.Quota_Bytes)
	testing.expect_value(t, len(a.items), 1)   // (refused whole: nothing written)
	rm := area_remove(&a, {"k", "absent"})
	testing.expect_value(t, len(rm), 1)
	testing.expect_value(t, a.bytes, 0)

	s: Area
	defer area_destroy(&s)
	s.max_item, s.max_items = 10, 2
	_, err = area_set(&s, {"long"}, {`"0123456789"`})
	testing.expect_value(t, err, Area_Error.Quota_Item)
	_, err = area_set(&s, {"a", "b", "c"}, {"1", "2", "3"})
	testing.expect_value(t, err, Area_Error.Quota_Items)
}

@(test)
test_area_roundtrip :: proc(t: ^testing.T) {
	a: Area
	defer area_destroy(&a)
	_, _ = area_set(&a, {"b", "a\tkey"}, {`{"x":[1,2]}`, `"text\nwith escapes"`})
	text := area_serialize(&a)
	b: Area
	defer area_destroy(&b)
	area_load(&b, text)
	testing.expect_value(t, len(b.items), 2)
	testing.expect_value(t, b.items["b"], `{"x":[1,2]}`)
	testing.expect_value(t, b.items["a\tkey"], `"text\nwith escapes"`)
	testing.expect_value(t, b.bytes, a.bytes)
	c: Area
	defer area_destroy(&c)
	area_load(&c, "garbage\n\"k\"\t1\n")
	testing.expect_value(t, len(c.items), 1)   // (a torn line loses that item only)
}

////////////////////////////////
// the list

@(test)
test_registry_list_roundtrip :: proc(t: ^testing.T) {
	reg: Registry
	registry_init(&reg, settings_default(), "", "en-US")
	defer registry_destroy(&reg)
	le := List_Entry{id = "odlameecjipmbmbejkplpemijjgpljce", path = "/a path/with\ttab", enabled = false, granted = {"https://*/*", "http://*/*"}}
	e := registry_add_listed(&reg, le)
	testing.expect(t, e.loading)
	testing.expect_value(t, len(e.grants), 2)
	text := registry_list_text(&reg)
	back := registry_list_parse(text)
	testing.expect_value(t, len(back), 1)
	testing.expect_value(t, back[0].id, le.id)
	testing.expect_value(t, back[0].path, le.path)
	testing.expect_value(t, back[0].enabled, false)
	testing.expect_value(t, len(back[0].granted), 2)
	testing.expect(t, extension_host_allowed(&reg, e, "https://example.com/a"))
	testing.expect(t, !extension_host_allowed(&reg, e, "file:///etc/passwd"))
	grant_set(&reg, e, "https://*/*", false)
	grant_set(&reg, e, "http://*/*", false)
	testing.expect(t, !extension_host_allowed(&reg, e, "https://example.com/a"))
	testing.expect_value(t, len(registry_list_parse("2\tother version\n" + "1\tnot an id\tchrome\tdir\tp\t1\t\n")), 0)
}
