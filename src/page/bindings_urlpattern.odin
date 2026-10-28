package page

// URLPattern as a host object (module url). The pattern parsing and matching are pure (package url, pattern*.odin);
// this holds the compiled url.Url_Pattern and the last exec() result so the C glue (native/js/runtime/web_urlpattern.c)
// can assemble the structured URLPatternResult (inputs, the eight URLPatternComponentResult with their group records).
//
// Native-first: no JavaScript prelude. The constructor parses the shorthand string or the URLPatternInit entirely in
// Odin; test()/exec() run the native matcher. Only the result-object assembly (a plain JS object with nested records)
// is in C, because it is pure Web IDL shape with no logic.

import "wb:url"

Pattern_Object :: struct {
	pat:    url.Url_Pattern,
	// the last successful match (exec): kept until the next exec or release, for the C glue to read out
	result: url.Pattern_Match_Result,
	has_result: bool,
}

pattern_vt := Object_VTable{
	name = "URLPattern",
	destroy = proc(p: ^Page, data: rawptr) {
		o := (^Pattern_Object)(data)
		url.pattern_destroy(&o.pat)
		if o.has_result { url.pattern_result_destroy(&o.result) }
		free(o)
	},
}

@(private)
pattern_obj :: proc(p: ^Page, h: u64) -> ^Pattern_Object { return (^Pattern_Object)(object_data(p, h, &pattern_vt)) }

lookup_URLPattern :: proc(c: ^Call, h: u64) -> ^Pattern_Object { return pattern_obj(c.page, h) }

@(private)
pattern_component :: proc(api: Api_URLPatternComponent) -> url.Pattern_Component {
	switch api {
	case .Protocol: return .Protocol
	case .Username: return .Username
	case .Password: return .Password
	case .Hostname: return .Hostname
	case .Port:     return .Port
	case .Pathname: return .Pathname
	case .Search:   return .Search
	case .Hash:     return .Hash
	}
	return .Protocol
}

// new URLPattern(patternString, baseURL?, {ignoreCase}).
URLPattern_createString :: proc(c: ^Call, input: string, base: string, has_base: bool, ignore_case: bool) -> (u64, Api_Error) {
	p := c.page
	if len(input) > p.settings.web.url_max_length { return 0, fail(c, .Type, "TypeError: the URLPattern is too long (url.max_length)") }
	init, ok := url.parse_constructor_string(input)
	if !ok { return 0, fail(c, .Type, "TypeError: invalid URLPattern string") }
	// per the spec: if no base and the parsed init has no protocol, it is a TypeError
	if !has_base {
		if _, has_proto := init.protocol.?; !has_proto {
			return 0, fail(c, .Type, "TypeError: a relative URLPattern requires a base URL")
		}
	} else {
		init.base_url = base
	}
	pat, pok := url.pattern_create(init, ignore_case)
	if !pok { return 0, fail(c, .Type, "TypeError: invalid URLPattern") }
	o := new(Pattern_Object)
	o.pat = pat
	return object_create(p, &pattern_vt, o, c.owner), .None
}

// new URLPattern(init, {ignoreCase}).
URLPattern_createInit :: proc(c: ^Call,
	protocol: string, has_protocol: bool, username: string, has_username: bool, password: string, has_password: bool,
	hostname: string, has_hostname: bool, port: string, has_port: bool, pathname: string, has_pathname: bool,
	search: string, has_search: bool, hash: string, has_hash: bool, base: string, has_base: bool, ignore_case: bool) -> (u64, Api_Error) {
	p := c.page
	init: url.Pattern_Init
	if has_protocol { init.protocol = protocol }
	if has_username { init.username = username }
	if has_password { init.password = password }
	if has_hostname { init.hostname = hostname }
	if has_port     { init.port = port }
	if has_pathname { init.pathname = pathname }
	if has_search   { init.search = search }
	if has_hash     { init.hash = hash }
	if has_base     { init.base_url = base }
	pat, pok := url.pattern_create(init, ignore_case)
	if !pok { return 0, fail(c, .Type, "TypeError: invalid URLPattern") }
	o := new(Pattern_Object)
	o.pat = pat
	return object_create(p, &pattern_vt, o, c.owner), .None
}

URLPattern_component :: proc(c: ^Call, pattern: Api_URLPattern, component: Api_URLPatternComponent) -> string {
	if pattern.data == nil { return "" }
	return url.pattern_component_string(&pattern.data.pat, pattern_component(component))
}

URLPattern_hasRegExpGroups :: proc(c: ^Call, pattern: Api_URLPattern) -> bool {
	if pattern.data == nil { return false }
	return url.pattern_has_regexp_groups(&pattern.data.pat)
}

@(private)
pattern_store_result :: proc(o: ^Pattern_Object, r: url.Pattern_Match_Result, matched: bool) -> i32 {
	if o.has_result { url.pattern_result_destroy(&o.result) }
	o.has_result = false
	if !matched { return 0 }
	o.result = r
	o.has_result = true
	return 1
}

URLPattern_execString :: proc(c: ^Call, pattern: Api_URLPattern, input: string, base: string, has_base: bool) -> i32 {
	o := pattern.data
	if o == nil { return 0 }
	bopt: Maybe(string) = has_base ? base : nil
	r, matched := url.pattern_match_url(&o.pat, input, bopt)
	return pattern_store_result(o, r, matched)
}

URLPattern_execInit :: proc(c: ^Call, pattern: Api_URLPattern,
	protocol: string, has_protocol: bool, username: string, has_username: bool, password: string, has_password: bool,
	hostname: string, has_hostname: bool, port: string, has_port: bool, pathname: string, has_pathname: bool,
	search: string, has_search: bool, hash: string, has_hash: bool) -> i32 {
	o := pattern.data
	if o == nil { return 0 }
	init: url.Pattern_Init
	if has_protocol { init.protocol = protocol }
	if has_username { init.username = username }
	if has_password { init.password = password }
	if has_hostname { init.hostname = hostname }
	if has_port     { init.port = port }
	if has_pathname { init.pathname = pathname }
	if has_search   { init.search = search }
	if has_hash     { init.hash = hash }
	r, matched := url.pattern_match_init(&o.pat, init)
	return pattern_store_result(o, r, matched)
}

URLPattern_resultInputCount :: proc(c: ^Call, pattern: Api_URLPattern) -> i32 {
	o := pattern.data
	if o == nil || !o.has_result { return 0 }
	return i32(len(o.result.inputs))
}

URLPattern_resultInput :: proc(c: ^Call, pattern: Api_URLPattern, index: i32) -> (string, Api_Error) {
	o := pattern.data
	if o == nil || !o.has_result || index < 0 || int(index) >= len(o.result.inputs) { return "", .Not_Found }
	return o.result.inputs[index], .None
}

URLPattern_componentInput :: proc(c: ^Call, pattern: Api_URLPattern, component: Api_URLPatternComponent) -> string {
	o := pattern.data
	if o == nil || !o.has_result { return "" }
	return o.result.values[pattern_component(component)]
}

URLPattern_groupCount :: proc(c: ^Call, pattern: Api_URLPattern, component: Api_URLPatternComponent) -> i32 {
	o := pattern.data
	if o == nil || !o.has_result { return 0 }
	return i32(len(o.result.groups[pattern_component(component)]))
}

URLPattern_groupName :: proc(c: ^Call, pattern: Api_URLPattern, component: Api_URLPatternComponent, index: i32) -> (string, Api_Error) {
	o := pattern.data
	if o == nil || !o.has_result { return "", .Not_Found }
	caps := o.result.groups[pattern_component(component)]
	if index < 0 || int(index) >= len(caps) { return "", .Not_Found }
	return caps[index].name, .None
}

URLPattern_groupValue :: proc(c: ^Call, pattern: Api_URLPattern, component: Api_URLPatternComponent, index: i32) -> (string, Api_Error) {
	o := pattern.data
	if o == nil || !o.has_result { return "", .Not_Found }
	caps := o.result.groups[pattern_component(component)]
	if index < 0 || int(index) >= len(caps) { return "", .Not_Found }
	if !caps[index].present { return "", .Not_Found }   // undefined for a group that did not participate
	return caps[index].value, .None
}
