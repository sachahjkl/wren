package page

import "core:testing"
import "wb:url"

@(private = "file")
O :: proc(s: string) -> url.Origin {
	u, _ := url.parse_absolute(s, context.temp_allocator)
	return url.origin_of(u, context.temp_allocator)
}

@(test)
sandbox_tokens :: proc(t: ^testing.T) {
	s := sandbox_parse("")
	testing.expect(t, s.active && s.allow == {}, "an empty sandbox allows nothing")
	s = sandbox_parse("  ALLOW-SCRIPTS\tallow-same-origin allow-bogus allow-top-navigation-by-user-activation ")
	testing.expect_value(t, s.allow, Sandbox_Allow{.Scripts, .Same_Origin, .Top_Navigation_By_User_Activation})
	testing.expect(t, sandbox_token_supported("allow-popups-to-escape-sandbox") && !sandbox_token_supported("allow-everything"))
	// nesting only narrows
	parent := sandbox_parse("allow-scripts allow-forms")
	child := sandbox_parse("allow-scripts allow-popups")
	testing.expect_value(t, sandbox_combine(parent, child).allow, Sandbox_Allow{.Scripts})
	testing.expect_value(t, sandbox_combine({}, child), child)
	testing.expect_value(t, sandbox_combine(parent, {}), parent)
	testing.expect(t, sandbox_allows({}, .Forms) && !sandbox_allows(child, .Forms))
}

@(test)
x_frame_options :: proc(t: ^testing.T) {
	self := O("https://a.example/")
	same := []url.Origin{O("https://a.example/x")}
	cross := []url.Origin{O("https://a.example/x"), O("https://b.example/")}
	testing.expect(t, xfo_allows({}, self, cross), "no header")
	testing.expect(t, !xfo_allows({"DENY"}, self, same), "DENY refuses even the same origin")
	testing.expect(t, xfo_allows({" sameorigin "}, self, same))
	testing.expect(t, !xfo_allows({"SAMEORIGIN"}, self, cross), "SAMEORIGIN checks every ancestor")
	testing.expect(t, xfo_allows({"ALLOWALL"}, self, cross))
	testing.expect(t, xfo_allows({"allow-from https://b.example"}, self, cross), "an invalid value allows (as browsers do)")
	testing.expect(t, !xfo_allows({"deny", "sameorigin"}, self, same), "conflicting values refuse")
	testing.expect(t, !xfo_allows({"deny, sameorigin"}, self, same), "conflicting values in one field refuse")
	testing.expect(t, xfo_allows({"sameorigin, SAMEORIGIN"}, self, same), "the same value twice is one value")
	testing.expect(t, xfo_allows({"foo, bar"}, self, cross), "several invalid values allow")
}

@(test)
permissions_policy :: proc(t: ^testing.T) {
	top := O("https://top.example/")
	widget := O("https://widget.example/")
	all := enabled_features({}, nil, top)
	testing.expect(t, .Publickey_Credentials_Get in all && .Fullscreen in all, "a top-level document has every default")

	// no allow attribute: 'self' features stay with the top level's origin
	off := inherited_disabled(all, top, nil, widget, widget)
	testing.expect(t, .Publickey_Credentials_Get in off && .Camera in off)
	testing.expect(t, .Sync_Xhr not_in off, "a * default reaches cross-origin frames")
	testing.expect(t, .Fullscreen not_in inherited_disabled(all, top, nil, top, top), "a same-origin frame keeps 'self' features")

	// allow="publickey-credentials-get; camera https://other.example; fullscreen 'none'; geolocation *; payment 'src'"
	pp := parse_allow_attribute("publickey-credentials-get; camera https://other.example; fullscreen 'none'; geolocation *; payment 'src'; bogus-feature")
	defer permissions_policy_destroy(&pp)
	testing.expect_value(t, len(pp.entries), 5)
	off = inherited_disabled(all, top, &pp, widget, widget)
	testing.expect(t, .Publickey_Credentials_Get not_in off, "a bare feature means 'src'")
	testing.expect(t, .Camera in off, "an allowlist naming another origin")
	testing.expect(t, .Fullscreen in off, "'none'")
	testing.expect(t, .Geolocation not_in off && .Payment not_in off)
	testing.expect(t, .Microphone in off, "not declared: its 'self' default")

	// what the parent itself does not have it cannot delegate
	parent_without := all - {.Payment}
	testing.expect(t, .Payment in inherited_disabled(parent_without, top, &pp, widget, widget))

	// allowfullscreen
	pf := parse_allow_attribute("", allowfullscreen = true)
	defer permissions_policy_destroy(&pf)
	testing.expect(t, .Fullscreen not_in inherited_disabled(all, top, &pf, widget, widget))

	// the header: geolocation=(), camera=(self "https://widget.example"), fullscreen=*
	hp := parse_permissions_policy_header({`geolocation=(), camera=(self "https://widget.example"), fullscreen=*;report-to=x`})
	defer permissions_policy_destroy(&hp)
	on := enabled_features({}, &hp, top)
	testing.expect(t, .Geolocation not_in on && .Camera in on && .Fullscreen in on && .Microphone in on)
	on = enabled_features({.Camera}, &hp, top)
	testing.expect(t, .Camera not_in on, "the header cannot enable what the container did not delegate")
}
