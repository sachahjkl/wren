package page

// What decides whether a nested document may exist and what it may do, as plain functions over strings and origins
// (unit tested in frames_policy_test.odin; frames.odin applies them):
//   * the sandbox attribute's tokens (HTML §7.1.6 "parse a sandboxing directive");
//   * X-Frame-Options (HTML §7.1.8 "check a navigation response's adherence to X-Frame-Options");
//   * Permissions Policy: the container policy of the allow attribute, the Permissions-Policy header, and whether a
//     feature is enabled in a document given its ancestors (Permissions Policy §9).

import "core:strings"
import "wb:url"

////////////////////////////////
// Sandbox

// The tokens of the sandbox attribute: what a sandboxed document is still allowed (nothing at all for an empty one).
Sandbox_Token :: enum u8 {
	Scripts,                               // allow-scripts
	Same_Origin,                           // allow-same-origin: the document keeps its origin (else an opaque one)
	Forms,                                 // allow-forms
	Popups,                                // allow-popups
	Popups_To_Escape_Sandbox,              // allow-popups-to-escape-sandbox
	Top_Navigation,                        // allow-top-navigation
	Top_Navigation_By_User_Activation,     // allow-top-navigation-by-user-activation
	Top_Navigation_To_Custom_Protocols,    // allow-top-navigation-to-custom-protocols
	Modals,                                // allow-modals
	Downloads,                             // allow-downloads
	Pointer_Lock,                          // allow-pointer-lock
	Orientation_Lock,                      // allow-orientation-lock
	Presentation,                          // allow-presentation
	Storage_Access_By_User_Activation,     // allow-storage-access-by-user-activation
}
Sandbox_Allow :: bit_set[Sandbox_Token; u16]

// A document's sandboxing: `active` false means none at all.
Sandbox :: struct {
	active: bool,
	allow:  Sandbox_Allow,
}

SANDBOX_TOKEN_NAMES := [Sandbox_Token]string{
	.Scripts = "allow-scripts", .Same_Origin = "allow-same-origin", .Forms = "allow-forms", .Popups = "allow-popups",
	.Popups_To_Escape_Sandbox = "allow-popups-to-escape-sandbox", .Top_Navigation = "allow-top-navigation",
	.Top_Navigation_By_User_Activation = "allow-top-navigation-by-user-activation",
	.Top_Navigation_To_Custom_Protocols = "allow-top-navigation-to-custom-protocols", .Modals = "allow-modals",
	.Downloads = "allow-downloads", .Pointer_Lock = "allow-pointer-lock", .Orientation_Lock = "allow-orientation-lock",
	.Presentation = "allow-presentation", .Storage_Access_By_User_Activation = "allow-storage-access-by-user-activation",
}

// The sandbox attribute's value: ASCII whitespace separated, ASCII case-insensitive tokens; unknown ones are ignored.
sandbox_parse :: proc(value: string) -> Sandbox {
	s := Sandbox{active = true}
	rest := value
	for tok in strings.fields_iterator(&rest) {
		for name, t in SANDBOX_TOKEN_NAMES {
			if strings.equal_fold(tok, name) { s.allow += {t} }
		}
	}
	return s
}

// The supported tokens (DOMTokenList.supports for iframe.sandbox).
sandbox_token_supported :: proc(tok: string) -> bool {
	for name in SANDBOX_TOKEN_NAMES { if strings.equal_fold(tok, name) { return true } }
	return false
}

// A nested document's sandboxing: its container's attribute (as of the navigation) on top of what its parent document
// already had (sandboxing only ever narrows down).
sandbox_combine :: proc(parent, container: Sandbox) -> Sandbox {
	if !parent.active { return container }
	if !container.active { return parent }
	return Sandbox{active = true, allow = parent.allow & container.allow}
}

sandbox_allows :: #force_inline proc(s: Sandbox, t: Sandbox_Token) -> bool { return !s.active || t in s.allow }

////////////////////////////////
// X-Frame-Options

// Whether a response with these X-Frame-Options values may be shown in a frame whose ancestors' origins are
// `ancestors` (parent first). `self` is the response's origin. Values are the header's fields, comma separated.
xfo_allows :: proc(values: []string, self: url.Origin, ancestors: []url.Origin) -> bool {
	opts := make([dynamic]string, context.temp_allocator)
	for v in values {
		for part in strings.split(v, ",", context.temp_allocator) {
			t := strings.to_lower(strings.trim_space(part), context.temp_allocator)
			if t == "" { continue }
			dup := false
			for o in opts { if o == t { dup = true } }
			if !dup { append(&opts, t) }
		}
	}
	if len(opts) == 0 { return true }
	if len(opts) > 1 {
		// conflicting values block; several invalid ones do not
		for o in opts { if o == "deny" || o == "sameorigin" || o == "allowall" { return false } }
		return true
	}
	switch opts[0] {
	case "deny": return false
	case "sameorigin":
		for a in ancestors { if !url.same_origin(a, self) { return false } }
	}
	return true
}

////////////////////////////////
// Permissions Policy

// The policy-controlled features the browser decides on (whether or not it implements them: an embedder's allow
// attribute is honoured the same way).
Feature :: enum u8 {
	Accelerometer, Ambient_Light_Sensor, Attribution_Reporting, Autoplay, Bluetooth, Browsing_Topics, Camera,
	Clipboard_Read, Clipboard_Write, Compute_Pressure, Cross_Origin_Isolated, Display_Capture, Encrypted_Media,
	Fullscreen, Gamepad, Geolocation, Gyroscope, Hid, Identity_Credentials_Get, Idle_Detection, Local_Fonts,
	Magnetometer, Microphone, Midi, Otp_Credentials, Payment, Picture_In_Picture, Publickey_Credentials_Create,
	Publickey_Credentials_Get, Screen_Wake_Lock, Serial, Storage_Access, Sync_Xhr, Usb, Web_Share, Window_Management,
	Xr_Spatial_Tracking,
}

FEATURE_NAMES := [Feature]string{
	.Accelerometer = "accelerometer", .Ambient_Light_Sensor = "ambient-light-sensor",
	.Attribution_Reporting = "attribution-reporting", .Autoplay = "autoplay", .Bluetooth = "bluetooth",
	.Browsing_Topics = "browsing-topics", .Camera = "camera", .Clipboard_Read = "clipboard-read",
	.Clipboard_Write = "clipboard-write", .Compute_Pressure = "compute-pressure",
	.Cross_Origin_Isolated = "cross-origin-isolated", .Display_Capture = "display-capture",
	.Encrypted_Media = "encrypted-media", .Fullscreen = "fullscreen", .Gamepad = "gamepad", .Geolocation = "geolocation",
	.Gyroscope = "gyroscope", .Hid = "hid", .Identity_Credentials_Get = "identity-credentials-get",
	.Idle_Detection = "idle-detection", .Local_Fonts = "local-fonts", .Magnetometer = "magnetometer",
	.Microphone = "microphone", .Midi = "midi", .Otp_Credentials = "otp-credentials", .Payment = "payment",
	.Picture_In_Picture = "picture-in-picture", .Publickey_Credentials_Create = "publickey-credentials-create",
	.Publickey_Credentials_Get = "publickey-credentials-get", .Screen_Wake_Lock = "screen-wake-lock", .Serial = "serial",
	.Storage_Access = "storage-access", .Sync_Xhr = "sync-xhr", .Usb = "usb", .Web_Share = "web-share",
	.Window_Management = "window-management", .Xr_Spatial_Tracking = "xr-spatial-tracking",
}

// Features whose default allowlist is * (every document, cross-origin frames included, unless a policy says
// otherwise); every other one defaults to 'self' (Chromium's defaults).
// (storage-access: * by the Storage Access API, its whole point being cross-site frames)
FEATURES_DEFAULT_ALL :: bit_set[Feature]{.Attribution_Reporting, .Browsing_Topics, .Cross_Origin_Isolated, .Gamepad, .Picture_In_Picture, .Storage_Access, .Sync_Xhr}

feature_by_name :: proc(name: string) -> (Feature, bool) {
	for n, f in FEATURE_NAMES { if n == name { return f, true } }
	return {}, false
}

// An allowlist: everything, or 'self' / 'src' and a list of origins (owned).
Allowlist :: struct {
	all:     bool,
	self:    bool,
	src:     bool,
	origins: [dynamic]url.Origin,
}

Policy_Entry :: struct {
	feature: Feature,
	list:    Allowlist,
}

// A declared policy (Permissions-Policy header) or a container policy (allow attribute), in declaration order; the
// first entry of a feature wins.
Permissions_Policy :: struct {
	entries: [dynamic]Policy_Entry,
}

permissions_policy_destroy :: proc(pp: ^Permissions_Policy) {
	for &e in pp.entries {
		for &o in e.list.origins { url.origin_destroy(&o) }
		delete(e.list.origins)
	}
	delete(pp.entries)
	pp^ = {}
}

@(private)
policy_has :: proc(pp: ^Permissions_Policy, f: Feature) -> ^Policy_Entry {
	for &e in pp.entries { if e.feature == f { return &e } }
	return nil
}

// The allow attribute (a container policy): "feature allowlist; feature allowlist..." where an allowlist is *,
// 'self', 'src', 'none' or origins; an empty one means 'src'. `allowfullscreen` adds fullscreen *, as HTML says.
parse_allow_attribute :: proc(value: string, allowfullscreen := false) -> Permissions_Policy {
	pp: Permissions_Policy
	for directive in strings.split(value, ";", context.temp_allocator) {
		toks := make([dynamic]string, context.temp_allocator)
		rest := directive
		for t in strings.fields_iterator(&rest) { append(&toks, t) }
		if len(toks) == 0 { continue }
		f, known := feature_by_name(strings.to_lower(toks[0], context.temp_allocator))
		if !known || policy_has(&pp, f) != nil { continue }
		e := Policy_Entry{feature = f}
		if len(toks) == 1 { e.list.src = true }
		for t in toks[1:] {
			switch strings.to_lower(t, context.temp_allocator) {
			case "*": e.list.all = true
			case "'self'": e.list.self = true
			case "'src'": e.list.src = true
			case "'none'":
			case:
				if o, ok := url.origin_parse(strings.trim_right(t, "/")); ok && !o.opaque { append(&e.list.origins, o) }
			}
		}
		append(&pp.entries, e)
	}
	if allowfullscreen && policy_has(&pp, .Fullscreen) == nil {
		append(&pp.entries, Policy_Entry{feature = .Fullscreen, list = {all = true}})
	}
	return pp
}

// The Permissions-Policy header (a structured-field dictionary): `feature=*`, `feature=()`, `feature=(self
// "https://a.example")`, `feature=self`. Unknown features and malformed members are skipped.
parse_permissions_policy_header :: proc(values: []string) -> Permissions_Policy {
	pp: Permissions_Policy
	for v in values {
		for member in split_top_level(v, ',') {
			m := strings.trim_space(member)
			eq := strings.index_byte(m, '=')
			if eq <= 0 { continue }
			f, known := feature_by_name(strings.to_lower(strings.trim_space(m[:eq]), context.temp_allocator))
			if !known || policy_has(&pp, f) != nil { continue }
			val := strings.trim_space(m[eq + 1:])
			if semi := strings.index_byte(val, ';'); semi >= 0 { val = strings.trim_space(val[:semi]) }   // parameters
			e := Policy_Entry{feature = f}
			items: []string
			if strings.has_prefix(val, "(") && strings.has_suffix(val, ")") {
				inner := val[1:len(val) - 1]
				list := make([dynamic]string, context.temp_allocator)
				rest := inner
				for t in strings.fields_iterator(&rest) { append(&list, t) }
				items = list[:]
			} else {
				items = {val}
			}
			for it in items {
				switch {
				case it == "*": e.list.all = true
				case it == "self": e.list.self = true
				case it == "src": e.list.src = true
				case len(it) >= 2 && it[0] == '"' && it[len(it) - 1] == '"':
					if o, ok := url.origin_parse(strings.trim_right(it[1:len(it) - 1], "/")); ok && !o.opaque { append(&e.list.origins, o) }
				}
			}
			append(&pp.entries, e)
		}
	}
	return pp
}

@(private)
split_top_level :: proc(s: string, sep: u8) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	depth, start := 0, 0
	quoted := false
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == '"': quoted = !quoted
		case quoted:
		case c == '(': depth += 1
		case c == ')': depth = max(depth - 1, 0)
		case c == sep && depth == 0:
			append(&out, s[start:i])
			start = i + 1
		}
	}
	append(&out, s[start:])
	return out[:]
}

// Does `list` match `origin`? `self` is the document's (or the container document's) origin, `src` the origin the
// container's src points at.
allowlist_matches :: proc(list: ^Allowlist, origin, self, src: url.Origin) -> bool {
	if list.all { return true }
	if list.self && url.same_origin(origin, self) { return true }
	if list.src && url.same_origin(origin, src) { return true }
	for o in list.origins { if url.same_origin(origin, o) { return true } }
	return false
}

// What a document inherits from its container (Permissions Policy §9.8 "define an inherited policy for feature in
// container at origin"): the features it may not enable whatever its own header says.
//   parent_enabled: the features enabled in the container's document; parent_origin: that document's origin;
//   container: the allow attribute's policy (nil when none); src: the origin of the container's src.
inherited_disabled :: proc(parent_enabled: bit_set[Feature], parent_origin: url.Origin, container: ^Permissions_Policy, origin, src: url.Origin) -> bit_set[Feature] {
	off: bit_set[Feature]
	for f in Feature {
		if f not_in parent_enabled { off += {f}; continue }
		if container != nil {
			if e := policy_has(container, f); e != nil {
				if !allowlist_matches(&e.list, origin, parent_origin, src) { off += {f} }
				continue
			}
		}
		if f in FEATURES_DEFAULT_ALL { continue }
		if !url.same_origin(origin, parent_origin) { off += {f} }
	}
	return off
}

// The features enabled in a document of `origin`, given what it inherited and its own declared policy (§9.9 "is
// feature enabled in document for origin", for the document's own origin).
enabled_features :: proc(inherited_off: bit_set[Feature], declared: ^Permissions_Policy, origin: url.Origin) -> bit_set[Feature] {
	on: bit_set[Feature]
	for f in Feature {
		if f in inherited_off { continue }
		if declared != nil {
			if e := policy_has(declared, f); e != nil {
				if allowlist_matches(&e.list, origin, origin, origin) { on += {f} }
				continue
			}
		}
		on += {f}   // the default allowlist, 'self' or *, holds for the document's own origin
	}
	return on
}
