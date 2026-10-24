package blocker

import "core:strings"

// Where each scriptlet of uBlock Origin's vocabulary is carried out. The blocker does not run JavaScript in a page when it can do the
// thing natively, in Odin:
//
//   .Dom      the document: attributes, classes, node text, clicks, links, cookies, storage. Done on the DOM by `dom_ops.odin`, fed by
//             the engine's mutation journal (new nodes only, once per batch), no realm involved.
//   .Network  JSON, XML and text in a response: done by the loader on the body before the page sees it (`rewrite.odin`), by URL.
//   .Hook     the behavior of an API of the realm (a property, a timer, fetch, a listener, JSON.parse): installed before the first script
//             as native hooks of the engine (`hooks.odin`, native/js/runtime/blocker.c): host functions, no interpreted wrapper.
//   .Js       none of the above fits: JavaScript run in the page (the rules written as raw `#%#` JavaScript, and nothing else).
//
// docs/blocker.md carries the same table.

Scriptlet_Route :: enum u8 { Dom, Network, Hook, Js }

// The name a scriptlet is known by: aliases and the `.js` suffix resolved, `trusted-` forms folded into theirs.
scriptlet_canonical :: proc(name: string) -> string {
	n := strings.trim_space(name)
	n = strings.trim_suffix(n, ".js")
	switch n {
	case "set", "set-constant", "trusted-set-constant": return "set-constant"
	case "aopr", "abort-on-property-read": return "abort-on-property-read"
	case "aopw", "abort-on-property-write": return "abort-on-property-write"
	case "acs", "acis", "abort-current-script", "abort-current-inline-script": return "abort-current-script"
	case "aost", "abort-on-stack-trace": return "abort-on-stack-trace"
	case "nostif", "no-setTimeout-if", "prevent-setTimeout", "setTimeout-defuser": return "no-setTimeout-if"
	case "nosiif", "no-setInterval-if", "prevent-setInterval", "setInterval-defuser": return "no-setInterval-if"
	case "nano-stb", "nano-setTimeout-booster": return "nano-setTimeout-booster"
	case "nano-sib", "nano-setInterval-booster": return "nano-setInterval-booster"
	case "nofetch", "no-fetch-if", "prevent-fetch": return "no-fetch-if"
	case "noxhr", "no-xhr-if", "prevent-xhr": return "no-xhr-if"
	case "aeld", "addEventListener-defuser", "prevent-addEventListener": return "addEventListener-defuser"
	case "nowoif", "no-window-open-if", "window.open-defuser": return "window.open-defuser"
	case "noeval", "noeval-if", "no-eval-if", "noeval.js": return "noeval"
	case "nowebrtc": return "nowebrtc"
	case "jp", "json-prune": return "json-prune"
	case "jpfr", "json-prune-fetch-response": return "json-prune-fetch-response"
	case "jpxhr", "json-prune-xhr-response": return "json-prune-xhr-response"
	case "xml-prune": return "xml-prune"
	case "trusted-replace-fetch-response", "trusted-rpfr", "replace-fetch-response": return "replace-fetch-response"
	case "trusted-replace-xhr-response", "trusted-rpxhr", "replace-xhr-response": return "replace-xhr-response"
	case "replace-in-response": return "replace-fetch-response"
	case "ra", "remove-attr": return "remove-attr"
	case "rc", "remove-class": return "remove-class"
	case "sa", "set-attr", "trusted-set-attr": return "set-attr"
	case "rmnt", "remove-node-text": return "remove-node-text"
	case "rpnt", "replace-node-text", "trusted-replace-node-text": return "replace-node-text"
	case "click-element", "trusted-click-element": return "click-element"
	case "href-sanitizer": return "href-sanitizer"
	case "disable-newtab-links": return "disable-newtab-links"
	case "set-cookie", "trusted-set-cookie": return "set-cookie"
	case "set-cookie-reload", "trusted-set-cookie-reload": return "set-cookie-reload"
	case "remove-cookie", "cookie-remover": return "remove-cookie"
	case "set-local-storage-item", "trusted-set-local-storage-item": return "set-local-storage-item"
	case "set-session-storage-item", "trusted-set-session-storage-item": return "set-session-storage-item"
	case "remove-local-storage-item": return "remove-local-storage-item"
	case "remove-session-storage-item": return "remove-session-storage-item"
	case "ubo-noop", "noop", "addEventListener-logger", "aell", "log-addEventListener", "json-edit", "spoof-css", "no-op": return "noop"
	}
	return n
}

scriptlet_route :: proc(canonical: string) -> Scriptlet_Route {
	switch canonical {
	case "remove-attr", "remove-class", "set-attr", "remove-node-text", "replace-node-text", "click-element", "href-sanitizer",
	     "disable-newtab-links", "set-cookie", "set-cookie-reload", "remove-cookie", "set-local-storage-item", "set-session-storage-item",
	     "remove-local-storage-item", "remove-session-storage-item", "noop":
		return .Dom
	case "json-prune-fetch-response", "json-prune-xhr-response", "xml-prune", "replace-fetch-response", "replace-xhr-response":
		return .Network
	case "set-constant", "abort-on-property-read", "abort-on-property-write", "abort-current-script", "abort-on-stack-trace",
	     "no-setTimeout-if", "no-setInterval-if", "nano-setTimeout-booster", "nano-setInterval-booster", "no-fetch-if", "no-xhr-if",
	     "addEventListener-defuser", "window.open-defuser", "noeval", "nowebrtc", "json-prune":
		return .Hook
	}
	return .Js
}
