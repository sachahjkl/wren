package page

// Top-level navigables: a tab, and the windows scripts open (HTML "auxiliary browsing contexts").
//
//   embedder (a tab of the browser, a window of the headless host) ── owns ──▶ Navigable (parent nil) ──▶ its active Page
//
// A top-level navigable outlives the documents it shows, as a frame's does: window.open() returns a WindowProxy of its id,
// which still names the window after the popup navigated. The embedder makes it (navigable_top_new), connects each of its
// documents to it (navigable_attach) and frees it with the window (navigable_top_free). A document of a shell that has no
// navigable of its own gets one on first use (page_navigable), owned by the document.
//
// What scripts see of it, shared by every embedder:
//   * window.open() to a name nothing has, or _blank, and a link to one: auxiliary_open asks the embedder of the opener's tab
//     for a new window (Embedder.open). The embedder makes it with its initial about:blank document (auxiliary_document: the
//     opener's origin, or an opaque one under noopener) and navigates it. The new window has the opener (window.opener), the
//     name, and the opener's browsing context group, unless noopener / noreferrer.
//   * The group: the windows a document finds by name (frames_find_target) and whose documents it reaches (frames_access.odin)
//     are those of its group: its own tab and the windows related to it by openers.
//   * window.close() of a window a script opened: closed at once for scripts, closed by its embedder in a task (Embedder.close).
//   * Cross-Origin-Opener-Policy (apply_isolation_headers): a response whose policy does not match that of the document it
//     replaces puts the navigable in a new browsing context group. Its id changes: the WindowProxies other windows hold
//     see it closed, its window.opener is null, its name is cleared, and the windows it opened lose their opener.

import "core:strings"
import "core:sync"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:url"

// Cross-Origin-Opener-Policy values (HTML "opener policy value"); Same_Origin_Plus_Coep is same-origin with an embedder
// policy that makes the document cross-origin isolated.
Opener_Policy :: enum u8 { Unsafe_None, Same_Origin_Allow_Popups, Same_Origin, Same_Origin_Plus_Coep, Noopener_Allow_Popups }

// What window.open's features (or a link's rel) ask of the new window.
Open_Features :: struct {
	noopener:   bool,   // no opener relationship: window.open returns null, the window is in a group of its own
	noreferrer: bool,   // no Referer either (implies noopener)
}

// A new window asked of the embedder (Embedder.open).
Open_Request :: struct {
	source:     ^Page,    // the document that asked (window.open, a link)
	url:        string,   // absolute; about:blank: the initial document stays
	noopener:   bool,     // its initial document has an opaque origin and nothing of the source
	noreferrer: bool,     // its navigation sends no Referer
}

// A top-level navigable for an embedder's window; it starts on its initial about:blank, in a browsing context group of its own.
navigable_top_new :: proc() -> ^Navigable {
	n := navigable_new()
	n.group = n.id
	n.initial = true
	return n
}

// The embedder's window is gone (its documents closed first, or left to close later): the windows holding its id see it closed.
navigable_top_free :: proc(n: ^Navigable) {
	if n == nil { return }
	if p := n.page; p != nil && p.frames != nil && p.frames.nav == n { p.frames.nav = nil }
	navigable_free(n)
}

// `p` is the active document of the top-level navigable `n` from now on (a document its embedder made for it).
navigable_attach :: proc(n: ^Navigable, p: ^Page) {
	if n == nil || p == nil || p.worker != nil { return }
	f := frames_of(p)
	if f.nav == n { n.page = p; return }
	if f.owns_nav && f.nav != nil { navigable_free(f.nav) }
	f.nav, f.owns_nav = n, false
	n.page = p
}

// The initial about:blank document of a new window `n` (HTML "create a new browsing context and document"), in the embedder's
// `scope`: the source's origin, base URL, referrer policy and, when the source is same origin with its top-level document, that
// document's opener policy; under noopener an opaque origin and nothing of the source. Connected to `n`, complete.
auxiliary_document :: proc(n: ^Navigable, req: Open_Request, scope: ^base.Scope, console: Console_Proc, console_user: rawptr) -> ^Page {
	src := req.source
	c := page_create(src.loop, src.loader, src.settings, scope, "about:blank", console, console_user)
	if req.noopener {
		env_set_origin(&c.env, url.new_opaque_origin())
	} else {
		env_set_origin(&c.env, url.origin_clone(src.env.origin))
		c.env.referrer_policy = src.env.referrer_policy
		top := page_top(src)
		if tn := page_navigable(top); tn != nil && url.same_origin(src.env.origin, top.env.origin) { n.coop = tn.coop }
	}
	url.site_destroy(&c.env.top_level_site)
	c.env.top_level_site = url.site_of(c.env.origin)
	url.origin_destroy(&n.coop_origin)
	n.coop_origin = url.origin_clone(c.env.origin)
	n.initial = true
	navigable_attach(n, c)
	f := frames_of(c)
	if !req.noopener { f.fallback_base = strings.clone(document_base_url(src)) }
	f.complete = true   // (nothing to load: scripts of the opener reaching it find a finished document, frames_make_live)
	return c
}

// A new window for `src` (window.open to _blank or to a name nothing has; a link to one): the sandbox and the content
// blocker's popup filters may refuse it, then the embedder of src's tab makes it. nil: no window was opened.
auxiliary_open :: proc(src: ^Page, href, name: string, feat: Open_Features) -> ^Navigable {
	sb := page_sandbox(src)
	if sb.active && .Popups not_in sb.allow {
		log(src, .Error, "Blocked opening a new window in a sandboxed frame without allow-popups.")
		return nil
	}
	// the content blocker's `$popup` filters: a popup a script opens without a recent click of the user is stopped. A popup the
	// user asked for (a gesture) is let through unless a filter explicitly names it.
	if check := embedder.popup_check; check != nil {
		if check(embedder.user, src, href, popup_has_gesture(src)) {
			log(src, .Log, strings.concatenate({"window.open blocked by the content blocker ($popup): ", href}, context.temp_allocator))
			return nil
		}
	}
	top := page_top(src)
	open := top.web.embedder.open
	sn := page_navigable(src)
	tn := page_navigable(top)
	if open == nil || sn == nil || tn == nil {
		log(src, .Warn, "window.open: this browser cannot open a new window here")
		return nil
	}
	noopener := feat.noopener || feat.noreferrer
	name := name
	// HTML "the rules for choosing a navigable": a document of another origin than its top-level one, whose policy is
	// same-origin, opens windows without an opener nor a name
	if (tn.coop == .Same_Origin || tn.coop == .Same_Origin_Plus_Coep) && !url.same_origin(src.env.origin, top.env.origin) {
		noopener, name = true, "_blank"
	}
	opener, group := sn.id, tn.group
	n := open(top.web.embedder.user, src, Open_Request{source = src, url = href, noopener = noopener, noreferrer = feat.noreferrer})
	if n == nil { return nil }
	n.script_opened = true
	if !strings.equal_fold(name, "_blank") {
		delete(n.name)
		n.name = strings.clone(name)
	}
	if !noopener { n.opener, n.group = opener, group }
	return n
}

// window.open's features argument (HTML "tokenize the features argument", "parse a boolean feature"): noopener and
// noreferrer; the others (sizes, popup) concern the shell's window and are not read.
open_features_parse :: proc(features: string) -> (out: Open_Features) {
	is_sep :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r' || c == '=' || c == ',' }
	s := features
	i := 0
	for i < len(s) {
		for i < len(s) && is_sep(s[i]) { i += 1 }
		start := i
		for i < len(s) && !is_sep(s[i]) { i += 1 }
		name := strings.to_lower(s[start:i], context.temp_allocator)
		for i < len(s) && s[i] != '=' {
			if s[i] == ',' || !is_sep(s[i]) { break }
			i += 1
		}
		value := ""
		if i < len(s) && is_sep(s[i]) {
			for i < len(s) && is_sep(s[i]) && s[i] != ',' { i += 1 }
			vstart := i
			for i < len(s) && !is_sep(s[i]) { i += 1 }
			value = strings.to_lower(s[vstart:i], context.temp_allocator)
		}
		switch name {
		case "noopener": out.noopener = open_feature_bool(value)
		case "noreferrer": out.noreferrer = open_feature_bool(value)
		}
	}
	return
}

// HTML "parse a boolean feature": empty, "yes", "true", or a non-zero integer (leading digits, after an optional sign).
@(private = "file")
open_feature_bool :: proc(value: string) -> bool {
	if value == "" || value == "yes" || value == "true" { return true }
	v := strings.trim_left(value, " \t\n\f\r")
	if len(v) > 0 && (v[0] == '-' || v[0] == '+') { v = v[1:] }
	for c in transmute([]u8)v {
		if c < '0' || c > '9' { break }
		if c != '0' { return true }
	}
	return false
}

// What a link's rel and target ask of the window it opens (HTML "get an element's noopener"): noreferrer implies noopener,
// and a link to _blank has none unless rel=opener.
link_open_features :: proc(rel, target: string) -> (out: Open_Features) {
	opener := false
	for tok in strings.fields(strings.to_lower(rel, context.temp_allocator), context.temp_allocator) {
		switch tok {
		case "noopener": out.noopener = true
		case "noreferrer": out.noreferrer, out.noopener = true, true
		case "opener": opener = true
		}
	}
	if strings.equal_fold(target, "_blank") && !opener { out.noopener = true }
	return
}

// The id of the navigable that opened top-level navigable `n` (window.opener): 0 for a frame, a window opened with
// noopener, one whose opener was severed or set to null, and once the opener is gone.
navigable_opener :: proc(n: ^Navigable) -> u64 {
	if n == nil || n.parent != nil || n.opener == 0 { return 0 }
	o := navigable_by_id(n.opener)
	if o == nil || o.page == nil || o.closing { return 0 }
	return o.id
}

// window.close() (HTML "close a browsing context"): only a window a script opened, and only when its embedder can close
// windows. It is closed for scripts at once; the embedder closes it from a task (never inside the script's call).
navigable_close :: proc(from: ^Page, n: ^Navigable) {
	if n == nil || n.parent != nil || n.closing || n.page == nil { return }
	p := n.page
	if !n.script_opened {
		log(from, .Warn, "Scripts may close only the windows that were opened by them.")
		return
	}
	if p.web == nil || p.web.embedder.close == nil { return }
	n.closing = true
	host.set_timer(p.loop, 0, 0, proc(data: rawptr) {
		n := navigable_by_id(u64(uintptr(data)))
		if n == nil { return }
		p := n.page
		if p == nil || p.closed || p.web == nil || p.web.embedder.close == nil { return }
		p.web.embedder.close(p.web.embedder.user, p)
	}, rawptr(uintptr(n.id)))
}

// Cross-Origin-Opener-Policy of a top-level document's response (the header's structured value: a token, maybe with
// parameters), its embedder policy making same-origin "same-origin-plus-COEP". Anything else is unsafe-none.
opener_policy_parse :: proc(values: []string, embedder_policy: fetch.Embedder_Policy) -> Opener_Policy {
	if len(values) != 1 || strings.contains_rune(values[0], ',') { return .Unsafe_None }   // (a list is no item)
	item := strings.trim(strings.split(values[0], ";", context.temp_allocator)[0], " \t")
	switch item {
	case "same-origin": return embedder_policy != .Unsafe_None ? .Same_Origin_Plus_Coep : .Same_Origin
	case "same-origin-allow-popups": return .Same_Origin_Allow_Popups
	case "noopener-allow-popups": return .Noopener_Allow_Popups
	}
	return .Unsafe_None
}

// HTML "check if COOP values require a browsing context group switch".
coop_requires_switch :: proc(initial: bool, active: Opener_Policy, active_origin: url.Origin, response: Opener_Policy, response_origin: url.Origin) -> bool {
	if response == .Noopener_Allow_Popups { return true }
	if active == .Unsafe_None && response == .Unsafe_None { return false }
	if initial && (active == .Same_Origin_Allow_Popups || active == .Noopener_Allow_Popups) && response == .Unsafe_None { return false }
	if active == response && url.same_origin(active_origin, response_origin) { return false }
	return true
}

// A top-level document `p` with opener policy `policy` replaces the navigable's active one: when their policies do not match,
// the navigable goes to a new browsing context group (navigable_new_group). Its policy and origin are `p`'s from now on.
navigable_commit_policy :: proc(n: ^Navigable, p: ^Page, policy: Opener_Policy) {
	if n == nil || n.parent != nil { return }
	if coop_requires_switch(n.initial, n.coop, n.coop_origin, policy, p.env.origin) { navigable_new_group(n) }
	n.coop = policy
	url.origin_destroy(&n.coop_origin)
	n.coop_origin = url.origin_clone(p.env.origin)
	n.initial = false
}

// HTML "browsing context group switch": the navigable is another browsing context for the other windows. A new id (the
// WindowProxies they hold see a closed window), no opener, no name, a group of its own.
@(private)
navigable_new_group :: proc(n: ^Navigable) {
	delete_key(&navigables, n.id)
	n.id = sync.atomic_add(&next_navigable_id, 1) + 1
	navigables[n.id] = n
	n.opener = 0
	n.group = n.id
	delete(n.name)
	n.name = ""
}

// The top-level documents of `p`'s browsing context group, its own first (temp).
group_tops :: proc(p: ^Page) -> []^Page {
	top := page_top(p)
	out := make([dynamic]^Page, 0, 1, context.temp_allocator)
	append(&out, top)
	tn := top.frames != nil ? top.frames.nav : nil
	if tn == nil { return out[:] }
	for _, n in navigables {
		if n.parent == nil && n != tn && n.group == tn.group && n.page != nil && !n.page.closed { append(&out, n.page) }
	}
	return out[:]
}

// The top-level navigable of `src`'s group named `name` (a window opened with that name, or named by its script).
@(private)
find_named_window :: proc(src: ^Page, name: string) -> ^Navigable {
	tn := page_navigable(page_top(src))
	if tn == nil { return nil }
	for _, n in navigables {
		if n.parent == nil && n.group == tn.group && n.name == name && n.page != nil && !n.closing { return n }
	}
	return nil
}
