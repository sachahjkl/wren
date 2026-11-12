package fetch

import "core:strings"
import "core:testing"
import "wb:base"
import "wb:extensions"
import "wb:url"

@(private = "file")
EXT_ID :: "odlameecjipmbmbejkplpemijjgpljce"
@(private = "file")
OTHER_ID :: "abcdefghijklmnopabcdefghijklmnop"

@(private = "file")
env_at :: proc(href: string) -> Environment {
	u, _ := url.parse(href, nil, context.temp_allocator)
	return environment_make(u)
}

// An installed, running extension with popup.html and a web-accessible img/ folder (for https://allowed.example).
@(private = "file")
test_registry :: proc(reg: ^extensions.Registry) {
	extensions.registry_init(reg, extensions.settings_default(), "", "en-US")
	im := new(extensions.Image, base.process_allocator())
	im.refs = 1
	_ = base.arena_init_growing(&im.arena)
	a := base.arena_allocator(&im.arena)
	im.ok = true
	im.id = strings.clone(EXT_ID, a)
	im.base_url = strings.clone("chrome-extension://" + EXT_ID + "/", a)
	im.files = make(map[string]extensions.File_Entry, 4, a)
	im.files["popup.html"] = {size = 1}
	im.files["img/logo.png"] = {size = 1}
	war := make([]extensions.Web_Resource, 1, a)
	res := make([]string, 1, a)
	res[0] = "img/*"
	pats := make([]extensions.Pattern, 1, a)
	pats[0], _ = extensions.pattern_parse("https://allowed.example/*")
	war[0] = {resources = res, matches = pats}
	im.manifest.web_accessible = war
	e := new(extensions.Extension)
	e.id = strings.clone(EXT_ID)
	e.enabled = true
	e.image = im
	append(&reg.list, e)
}

@(test)
test_extension_may_load_rules :: proc(t: ^testing.T) {
	reg: extensions.Registry
	test_registry(&reg)
	defer extensions.registry_destroy(&reg)
	im := reg.list[0].image
	// rule 2: the browser itself (the address bar, the shell's popup)
	testing.expect(t, extension_may_load(nil, im, "popup.html"))
	// rule 1: the extension's own documents
	own := env_at("chrome-extension://" + EXT_ID + "/popup.html")
	defer environment_destroy(&own)
	testing.expect(t, extension_may_load(&own, im, "popup.html"))
	// rule 3: a web-accessible resource, for the pages its `matches` cover
	allowed := env_at("https://allowed.example/page")
	defer environment_destroy(&allowed)
	testing.expect(t, extension_may_load(&allowed, im, "img/logo.png"))
	testing.expect(t, !extension_may_load(&allowed, im, "popup.html"))
	// rule 4: anything else
	other := env_at("https://other.example/")
	defer environment_destroy(&other)
	testing.expect(t, !extension_may_load(&other, im, "img/logo.png"))
	another := env_at("chrome-extension://" + OTHER_ID + "/x.html")
	defer environment_destroy(&another)
	testing.expect(t, !extension_may_load(&another, im, "popup.html"))
}

// A page cannot tell "refused" from "not installed" or "no such file": every one resolves to nothing, and the hop answers
// the same error for nothing.
@(test)
test_extension_same_error :: proc(t: ^testing.T) {
	reg: extensions.Registry
	test_registry(&reg)
	defer extensions.registry_destroy(&reg)
	page := env_at("https://other.example/")
	defer environment_destroy(&page)
	resolve :: proc(reg: ^extensions.Registry, href: string, env: ^Environment) -> bool {
		u, _ := url.parse(href, nil, context.temp_allocator)
		e, _ := extension_resolve(reg, u, env)
		return e != nil
	}
	refused := resolve(&reg, "chrome-extension://" + EXT_ID + "/popup.html", &page)
	absent_file := resolve(&reg, "chrome-extension://" + EXT_ID + "/nothing.html", &page)
	absent_ext := resolve(&reg, "chrome-extension://" + OTHER_ID + "/popup.html", &page)
	traversal := resolve(&reg, "chrome-extension://" + EXT_ID + "/img/%2e%2e/%2e%2e/popup.html", &page)
	testing.expect(t, !refused && !absent_file && !absent_ext && !traversal)
	testing.expect(t, resolve(&reg, "chrome-extension://" + EXT_ID + "/popup.html", nil))
	testing.expect(t, resolve(&reg, "chrome-extension://" + EXT_ID + "/img/../popup.html", nil))   // (normalised inside the package)
	// disabled: as absent
	reg.list[0].enabled = false
	testing.expect(t, !resolve(&reg, "chrome-extension://" + EXT_ID + "/popup.html", nil))
}

// The extension origin is a tuple origin and a secure context (url package).
@(test)
test_extension_origin :: proc(t: ^testing.T) {
	u, ok := url.parse("chrome-extension://" + EXT_ID + "/popup/index.html", nil, context.temp_allocator)
	testing.expect(t, ok)
	o := url.origin_of(u, context.temp_allocator)
	testing.expect(t, !o.opaque)
	testing.expect_value(t, o.host, EXT_ID)
	testing.expect_value(t, url.origin_serialize(o, context.temp_allocator), "chrome-extension://" + EXT_ID)
	testing.expect(t, url.is_potentially_trustworthy(u))
}
