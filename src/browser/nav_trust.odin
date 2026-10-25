package browser

import "core:fmt"
import "core:strings"
import "wb:fetch"
import "wb:page"
import "wb:url"

// Who chose the address of a navigation, and what that earns it.
//
// An address is trusted (opened with no initiator, so `file:` and network shares are allowed; the effects of the browser's
// own pages run) only when a person gave it: the address bar, a menu, a bookmark, the command line, a dropped file. It is
// never trusted because the code that navigates forgot to say where it came from: the zero value is `.Page`, the
// least-privileged origin, and a navigation that is not told otherwise gets none of the privileges below.
Nav_Origin :: enum u8 {
	Page,     // a document chose it (a link, a script, a form, a frame...): `from` is that document, nil when it is gone
	User,     // a person did (and the browser's own commands: the homepage, about:config...)
	Replay,   // the browser shows an entry it already accepted again (back, forward, reload, a restored tab): no effects
}

Nav_Verdict :: struct {
	address: string,   // what the entry, the tab and the loader get (temp allocator): the effects of a page that is not allowed to act are cut
	acts:    bool,     // the effects of the address (clearing data, removing or installing a licence) may run
	trusted: bool,     // opened as the address bar would (no initiator): a person, or a page of the browser itself
	refuse:  string,   // not empty: the navigation does not happen, and nothing of it is recorded (temp allocator)
}

// Says why a navigation did not happen: in the console of the document that asked (the tab's when none is left).
nav_refused :: proc(t: ^Tab, from: ^page.Page, target, why: string) {
	message := fmt.tprintf("%s %s", why, target)
	if from != nil { page.log(from, .Error, message) } else { tab_log(t, .Error, message) }
}

// The documents allowed to act through the address: the page's own links and forms (about:sites?clear=... is a link of
// about:sites). nil: the address has no effects.
nav_own_page :: proc(target: string) -> (own: proc(href: string) -> bool) {
	switch {
	case is_sites_address(target): return is_sites_address
	case is_cache_address(target): return is_cache_address
	case is_wren_address(target), is_license_file_address(target): return is_builtin_href
	}
	return nil
}

// What a navigation to `target` (normalised) is allowed to do. `from`: the environment of the document that asked (nil: none,
// or it is gone); `policy`: security.file_access.policy. Pure: it decides, it changes nothing.
nav_judge :: proc(origin: Nav_Origin, from: ^fetch.Environment, policy: fetch.File_Access, target: string) -> (v: Nav_Verdict) {
	from_href := from != nil ? from.location.href : ""
	v.trusted = origin == .User || (origin == .Page && is_builtin_href(from_href))   // (a link of about:demos opens as the address bar would)
	v.address = target
	if own := nav_own_page(target); own != nil {
		v.acts = origin == .User || (origin == .Page && from_href != "" && own(from_href))
		if !v.acts && !is_license_file_address(target) { v.address = nav_neutral_address(target) }
	}
	if origin == .Page && !v.trusted {
		inner := target
		for strings.has_prefix(inner, VIEW_SOURCE) { inner = inner[len(VIEW_SOURCE):] }
		if len(inner) >= 5 && strings.equal_fold(inner[:5], "file:") {
			host := ""
			if u, ok := url.parse(inner, allocator = context.temp_allocator); ok { host = u.host }
			if from == nil || from.location.scheme != "file" || !fetch.file_navigation_allowed(from, policy, host) {
				v.refuse = "Blocked: a web page cannot open a file of this computer or a network share (the address bar can)."
			}
		}
	}
	return
}

// The address without what it would do: of the query only the parameters that change nothing (the filter of about:sites and
// about:cache, the sample card of about:wren). A name is kept as written, never decoded: `cl%65ar` is not `q`.
nav_neutral_address :: proc(target: string) -> string {
	name_q, name_card := [1]string{"q"}, [1]string{"card"}
	names := is_wren_address(target) ? name_card[:] : name_q[:]
	rest, fragment := target, ""
	if i := strings.index_byte(rest, '#'); i >= 0 { rest, fragment = rest[:i], rest[i:] }
	query := ""
	if i := strings.index_byte(rest, '?'); i >= 0 { rest, query = rest[:i], rest[i + 1:] }
	kept := make([dynamic]string, context.temp_allocator)
	for part in strings.split(query, "&", context.temp_allocator) {
		name := part
		if i := strings.index_byte(part, '='); i >= 0 { name = part[:i] }
		for n in names { if name == n { append(&kept, part); break } }
	}
	if len(kept) == 0 { return strings.concatenate({rest, fragment}, context.temp_allocator) }
	return strings.concatenate({rest, "?", strings.join(kept[:], "&", context.temp_allocator), fragment}, context.temp_allocator)
}

// The document a developer tools panel inspects (the current tab's): the addresses it offers to open come from that
// document's requests and markup, so they open under its rules (a web page's file: address stays refused).
inspected_page :: proc(app: ^App) -> ^page.Page {
	if t := current_tab(app); t != nil { return t.page }
	return nil
}
