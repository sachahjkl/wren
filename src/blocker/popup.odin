package blocker

import "wb:adblock"
import "wb:page"

// `$popup` filters: the lists name the pop-up windows and tabs an ad or a tracker tries to open (`||ads.example^$popup`,
// `example.com^$popup`, `$popup,domain=`, exceptions `@@||x^$popup`). The page's `window.open` path (and any other place
// the browser creates a child window / tab for a page) asks the blocker here, with the opener document and the target URL.
//
// Semantics, as uBlock Origin / Adblock Plus have them:
//   * a pop-up a script opens on its own (no recent click or key press in the opener) that matches a `$popup` filter is
//     stopped;
//   * a pop-up the user asked for (a gesture) is let through unless a `$popup` filter explicitly matches it and no
//     exception applies: uBlock stops user-triggered pop-ups too when a block filter names them, so we match the engine's
//     verdict and only spare a gesture-backed opening to the opener's own origin (never named by a filter there);
//   * an exception (`@@||x^$popup`, `$~popup` on a block rule) wins, as for every request type.
//
// The hook is installed in install_page_hooks (page_hooks.odin): `page.embedder.popup_check`.

// Installed as page.embedder.popup_check. Returns true to stop the opening. `user` is the Blocker; `p` the opener document;
// `url` the absolute target; `gesture` whether a recent user activation backs the opening.
@(private)
popup_check :: proc(user: rawptr, p: ^page.Page, url: string, gesture: bool) -> bool {
	b := (^Blocker)(user)
	if !b.cfg.enabled || !b.cfg.popup || b.engine == nil { return false }
	d := doc_of_page(b, p)
	opener_url := ""
	opener_host := ""
	opener_domain := ""
	site := Site_Flags{}
	unfiltered := false
	if d != nil {
		opener_url, opener_host, opener_domain = d.href, d.host, d.domain
		site, unfiltered = d.site, d.unfiltered
	} else {
		loc := &p.env.location
		opener_url, opener_host = loc.href, loc.host
		opener_domain = adblock.registrable_domain(opener_host)
		site = site_flags(b, opener_host)
		unfiltered = .Off in site
	}
	if unfiltered || .Off in site { return false }

	req := adblock.Request{url = url, type = .Popup, method = .Get}
	req.host = adblock.url_host(url)
	if req.host == "" { return false }
	req.source_url, req.source_host, req.source_domain = opener_url, opener_host, opener_domain
	req.third_party = req.source_domain != "" && adblock.registrable_domain(req.host) != req.source_domain

	v := adblock.match(b.engine.engine, &req)
	rule := u32(adblock.NO_FILTER)
	blocked := false
	#partial switch v.action {
	case .Block:     blocked = true; rule = v.filter
	case .Exception: blocked = false; rule = v.filter
	case .Allow:     blocked = false
	}
	// a gesture-backed opening to the opener's own registrable domain is never a pop-up ad: let it through even if a broad
	// `$popup` rule would catch it (uBlock does not stop a same-site window the user opened)
	if blocked && gesture && !req.third_party { blocked = false }

	if blocked {
		reason := rule_text(b, b.engine, rule)
		popup_blocked_record(b, opener_url, url, reason)
	}
	return blocked
}
