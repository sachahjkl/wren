package blocker

import "core:testing"

@(private = "file")
make_op :: proc(o: ^Dom_Ops, args: ..string) -> (op: ^Dom_Op, ok: bool) {
	canon := scriptlet_canonical(args[0])
	d, good := ops_make(canon, args)
	if !good { return nil, false }
	append(&o.ops, d)
	return &o.ops[len(o.ops) - 1], true
}

@(test)
test_scriptlet_names_and_routes :: proc(t: ^testing.T) {
	testing.expect_value(t, scriptlet_canonical("rpnt"), "replace-node-text")
	testing.expect_value(t, scriptlet_canonical("trusted-replace-node-text"), "replace-node-text")
	testing.expect_value(t, scriptlet_canonical("remove-attr.js"), "remove-attr")
	testing.expect_value(t, scriptlet_canonical("ra"), "remove-attr")
	testing.expect_value(t, scriptlet_canonical("set"), "set-constant")
	testing.expect_value(t, scriptlet_canonical("acis"), "abort-current-script")
	testing.expect_value(t, scriptlet_canonical("jpfr"), "json-prune-fetch-response")
	testing.expect_value(t, scriptlet_canonical("trusted-replace-fetch-response"), "replace-fetch-response")
	testing.expect_value(t, scriptlet_canonical("nostif"), "no-setTimeout-if")
	testing.expect_value(t, scriptlet_canonical("something-new"), "something-new")
	testing.expect_value(t, scriptlet_route("remove-class"), Scriptlet_Route.Dom)
	testing.expect_value(t, scriptlet_route("click-element"), Scriptlet_Route.Dom)
	testing.expect_value(t, scriptlet_route("set-cookie"), Scriptlet_Route.Dom)
	testing.expect_value(t, scriptlet_route("json-prune-xhr-response"), Scriptlet_Route.Network)
	testing.expect_value(t, scriptlet_route("xml-prune"), Scriptlet_Route.Network)
	testing.expect_value(t, scriptlet_route("set-constant"), Scriptlet_Route.Hook)
	testing.expect_value(t, scriptlet_route("no-fetch-if"), Scriptlet_Route.Hook)
	testing.expect_value(t, scriptlet_route("json-prune"), Scriptlet_Route.Hook)
	testing.expect_value(t, scriptlet_route("something-new"), Scriptlet_Route.Js)
}

@(test)
test_ops_remove_attr_and_class :: proc(t: ^testing.T) {
	o: Dom_Ops
	defer ops_destroy(&o, nil)
	// uBlock Origin: remove-attr(attr[, selector[, behavior]]); the default selector is every element that has the attribute
	op, ok := make_op(&o, "remove-attr", "onclick|data-ad")
	testing.expect(t, ok)
	testing.expect_value(t, len(op.names), 2)
	testing.expect_value(t, op.selector, "[onclick],[data-ad]")
	testing.expect(t, !op.explicit && !op.stay && !op.asap)
	op, ok = make_op(&o, "ra", "href", "a.x", "asap stay")
	testing.expect(t, ok && op.explicit && op.stay && op.asap)
	testing.expect_value(t, op.selector, "a.x")
	op, ok = make_op(&o, "rc", "ad|promo")
	testing.expect(t, ok)
	testing.expect_value(t, op.selector, ".ad,.promo")
	_, ok = make_op(&o, "remove-attr")
	testing.expect(t, !ok)
	// disable-newtab-links is a watching removal of target on the links that open a tab
	op, ok = make_op(&o, "disable-newtab-links")
	testing.expect(t, ok && op.stay && op.kind == .Remove_Attr)
}

@(test)
test_ops_text :: proc(t: ^testing.T) {
	o: Dom_Ops
	defer ops_destroy(&o, nil)
	op, ok := make_op(&o, "rpnt", "script", "/(\\d+)px/g", "$1em", "sedCount", "2", "condition", "banner")
	testing.expect(t, ok)
	testing.expect_value(t, op.kind, Dom_Op_Kind.Replace_Text)
	testing.expect_value(t, op.node_name, "script")
	testing.expect_value(t, op.sed_count, 2)
	testing.expect(t, op.has_cond)
	out, changed := rewrite_text(op, "a banner 10px and 20px and 30px")
	testing.expect(t, changed)
	testing.expect_value(t, out, "a banner 10em and 20em and 30px")
	_, changed = rewrite_text(op, "a header 10px")   // the condition does not match
	testing.expect(t, !changed)
	// a pattern that is not a regular expression is the text itself, every occurrence
	op, ok = make_op(&o, "replace-node-text", "script", "a.b", "X")
	testing.expect(t, ok)
	out, changed = rewrite_text(op, "a.b axb a.b")
	testing.expect_value(t, out, "X axb X")
	// remove-node-text empties the node whose text matches
	op, ok = make_op(&o, "rmnt", "script", "/ads?Loader/")
	testing.expect(t, ok)
	out, changed = rewrite_text(op, "var adsLoader = 1")
	testing.expect(t, changed && out == "")
	_, changed = rewrite_text(op, "var other = 1")
	testing.expect(t, !changed)
	// a node name that is a regular expression
	op, ok = make_op(&o, "rpnt", "/^(script|style)$/", "a", "b")
	testing.expect(t, ok && op.node_re != nil)
	testing.expect(t, name_matches(op, "style") && name_matches(op, "SCRIPT") && !name_matches(op, "div"))
	// an invalid pattern is not an operation
	_, ok = make_op(&o, "rpnt", "script", "/(/", "b")
	testing.expect(t, !ok)
}

@(test)
test_ops_click_and_storage :: proc(t: ^testing.T) {
	o: Dom_Ops
	defer ops_destroy(&o, nil)
	op, ok := make_op(&o, "trusted-click-element", "button.accept, a[href=\"x,y\"] , #next", "", "250")
	testing.expect(t, ok)
	testing.expect_value(t, len(op.sels), 3)
	testing.expect_value(t, op.sels[1], "a[href=\"x,y\"]")
	testing.expect_value(t, op.delay_ms, 250)
	op, ok = make_op(&o, "set-cookie", "consent", "accepted", "none")
	testing.expect(t, ok && op.kind == .Set_Cookie)
	testing.expect_value(t, op.path, "")
	op, ok = make_op(&o, "set-cookie", "consent", "accepted")
	testing.expect_value(t, op.path, "/")
	op, ok = make_op(&o, "set-session-storage-item", "k", "true")
	testing.expect(t, ok && op.session && op.kind == .Set_Storage)
	op, ok = make_op(&o, "remove-local-storage-item", "k")
	testing.expect(t, ok && !op.session && op.kind == .Remove_Storage)
	op, ok = make_op(&o, "remove-cookie", "/^_ga/")
	testing.expect(t, ok && op.pat != nil && jsre_test(op.pat, "_ga_ABC") && !jsre_test(op.pat, "session"))
	op, ok = make_op(&o, "set-attr", "#a", "data-x", "1")
	testing.expect(t, ok && op.stay && op.names[0] == "data-x" && op.value == "1")
	_, ok = make_op(&o, "set-attr", "#a")
	testing.expect(t, !ok)
}
