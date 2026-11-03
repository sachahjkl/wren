# The DOM of a same-origin frame

Each document has its own JavaScript realm: an instance of the engine, compiled to Wasm, with its own heap. A browser's frames
share a heap between documents of one origin, and pages rely on it: `iframe.contentDocument.write(html)`,
`frame.contentWindow.someGlobal`, `parent.document`, `window.parent.foo()`, rich-text editors, payment widgets, test
harnesses. Wren gets the same result without sharing a heap, in two parts.

## Nodes: handles that name their document

The DOM lives on the browser's side; a wrapper in a realm is a handle. A handle now says which document it belongs to: 15
bits of its generation word are the document's tag (`base.pool_insert_tagged`, `src/base/pool.odin`). So a wrapper of a realm
can hold a node of another document, and `contentDocument` and all that is reached from it are ordinary DOM wrappers of the
caller's realm.

Every generated import trampoline hands its handle arguments to `api_route` (`src/page/api_host.odin`). A handle of another
document moves the whole call to that document: `Call.page` is that page, `Call.caller` the one whose realm is calling, and the
implementation does what it does for a page calling itself, so the frame's styles, layout, hooks and scripts follow. Imports
of `Document` that name no node (`createTextNode`, `title`, `write`...) are preceded by a one-shot `Frame_target`.

What keeps a frame of another origin out:

- a handle resolves in its own document only. The tag is in the slot's generation, so a handle given to the wrong document fails
  like a dead one, in any implementation, routed or not;
- the document is looked up on each call, among the documents of the caller's tab, and its origin compared with the
  caller's (`frames_may_reach`, `src/page/frames_access.odin`). A frame gone, navigated to another origin, or sandboxed without
  `allow-same-origin` leaves handles that resolve to nothing;
- a cross-origin frame's nodes never get a handle in another realm in the first place: `contentDocument` is null,
  `contentWindow.document` and `parent.document` throw a `SecurityError`.

`document.domain` has no setter in Wren, so it never widens an origin.

An insertion of a node of another document moves it first (DOM "adopt", `Frame_adoptNode`): a node has its handle in its
document's pool, so this makes new nodes, with their listeners, and the wrappers of the realm that asked follow them. A
custom element keeps its definition: its reactions run in the realm that defined it, `adoptedCallback` included. A
wrapper another realm holds on the old node goes dead; a shadow root does not follow its host; a form control's typed
value and the state of a media element stay behind. `document.adoptNode` and `importNode` across documents leave the node where
it is until it is inserted, so `ownerDocument` tells the old document until then.

A wrapper belongs to a realm: the same element has one wrapper per realm that reached it, and a property set on one is
not on the other. A method of a custom element of the frame's registry is not visible on the parent's wrapper of it. A
`MutationObserver` follows other documents with a browser object in each. The methods of a wrapper are its realm's, but
one given too few arguments throws the `TypeError` of the node's realm (`throw_arity_of`, `frames_bridge.odin`), as the
node's own method would in a browser: `frame.contentWindow.TypeError`.

Listeners may come from both realms. A listener added from another realm records a `Foreign_Owner` (its page, its instance), and
runs in the realm that added it, a nested instance call. A script inserted in a frame runs in the frame's realm, wherever its
element was made. All documents of a tab are on one thread, so a nested call needs no lock; the native stack check of
`src/wasm` ends a recursion through realms as it ends one in a realm.

A document with a running call in it cannot be freed: `page_close` then takes it out of the tree at once and closes it when
the call has returned (`frames_close_later`). The script goes on, in a document nobody can reach.

## Blank frames

A frame with no address (`about:blank`, the initial document) is a real document with a realm of its own, like any other,
made on first need. Reached by another realm, it becomes a document that finished loading, shown in its frame
(`frames_make_live`).

The first document that replaces it keeps its `Window` when it is of the same origin, as HTML says: what a script put on the
blank frame's window (`frame.contentWindow.navigation.onnavigate = ...`, `window[0].foo = ...`, its listeners and timers) is the
next document's. The blank document's `Page` takes the new document (`frame_keep_window`, `src/page/frames.odin`) instead of a
`Page` of its own, but only when its realm was started: a blank frame no script touched has nothing to keep. The realm, its
instance and the `Window`'s objects stay; the new tree gets a tag of its own when it is parsed, so that a wrapper of the blank
document is dead in every realm, while the objects the `Window` made keep the old tag (`Page.prior_tag`, which the routing of
`frames_access.odin` takes for the page's own). The URL, the policies, the frames and the scripts are the new document's, and the
realm forgets what belongs to the document (`wj_document_replaced`): `history`, the custom element registry with its definitions,
`navigation.activation`. A document of another origin, or one a sandbox makes opaque, gets a `Window` of its own.

## Globals: a value bridge

`frame.contentWindow.foo` and `parent.foo()` go through `native/js/odin/frames_bridge.odin` and `web_bridge.js`. A request is
bytes the browser carries from an instance to another (`Frame_bridge`, which checks the origin each time):

| value | in the other realm |
|---|---|
| undefined, null, booleans, numbers, strings, bigints | copied |
| well-known symbols | by name; any other symbol is not carried |
| a DOM node | that realm's wrapper of the node |
| a window | that realm's `WindowProxy`, or its global |
| an interface object, its prototype | by name: that realm's own (a node is that realm's wrapper, with its prototypes) |
| any other object, a function, an ECMAScript built-in | a `Proxy` forwarding get, set, has, delete, keys, descriptors, prototype, call, construct |

An object coming home is itself. A realm that is gone answers `undefined`. Proxies are collected with `FinalizationRegistry`, which
releases the object in its realm.

Each window keeps its ECMAScript built-ins, as in a browser: `w.Array !== Array`, `new w.Object` and `new w.Array` are objects of `w`
with `w`'s prototypes, `x instanceof Array` is false for an array of `w` and `x instanceof w.Array` true, `Array.isArray` sees
through (it is how pages tell an array of another frame), and what `w` throws is a `w.TypeError`, not a `TypeError`. A built-in
reached through a window is a `Proxy` like any other object of it, so each use of it crosses: measured on a page calling into a
frame 2000 times (`jspage`, a dev build, 2026-11-02), a call `w.add(i, 1)` costs 15 µs before and after and a read `w.obj.a` 11 µs;
reading `w.Array` went from 1 µs (the reader's own) to 10 µs, `w.Array.isArray([])` from 1 to 99 µs (a new array goes to `w` as an
object, which `w` releases later: 30 µs when `w` already holds it), `new w.Object` from 1 to 35 µs, `xOfW instanceof Array` from 6
to 19 µs (each prototype is asked of `w`). A page that takes a built-in of a frame once and calls it in a loop pays a crossing per call.

A listener or a handler that is a `Proxy` of another realm's function runs as a callback of that realm: what it throws is reported at
that window's `error` event, and once that realm is gone it is not called. A listener of another realm that cannot be called (no
`handleEvent`, one that is not callable, a revoked `Proxy`) fails with a `TypeError` of that realm, reported there.

What it is not is one heap:

- the interface objects are the exception to the rule above: `w.HTMLElement === HTMLElement`, because a node of `w`'s document is the
  reader's wrapper of it. `w.document.body instanceof w.HTMLElement` holds, and so does `instanceof HTMLElement`, where a browser
  says false; `new w.Event("x")` makes an event of the reader;
- a native function refuses a `Proxy` for one of its own objects: a typed array or a `Blob` of one realm passed to a native of
  another throws a `TypeError`. An `Event` to `otherWindow.dispatchEvent` is handled, and `frameDocument.createRange()` and
  `getSelection()` give the frame's own, which its `Selection` takes;
- a cycle between two realms (a listener of one kept by the other) lives until one of them goes;
- `navigator`, `screen`, `crypto` and `console` of another window are the caller's (a page takes a clean `crypto` from a blank frame
  and hands it typed arrays of its own, which the frame's would refuse);
- a frame without a realm (sandboxed without `allow-scripts`) gives the caller's native constructors for its upper-case names;
- `w.Function.prototype.toString.call(f)` on a function of the caller says `[native code]`: the frame sees a `Proxy`.

A custom element class of one realm defined in the registry of another (`frame.contentWindow.customElements.define(name, class extends
HTMLElement {})`) is not supported: its constructor would run in one realm for an element of another.

Rich-text editors reach their frame, but Wren has no editing of its own in `contenteditable` or `designMode` (typing, caret, `execCommand`):
that limit is not about frames.

## Navigating a frame

A navigable keeps its session history across its documents (`Navigable.session`): `navigation.entries()`, `back()`, `traverseTo()` and
`reload()` see them, keys and ids stay. The navigate event fires in the frame's document whoever starts the navigation (`location` of
another window, `window.open` or a link or a form with a target, the `src` and `srcdoc` attributes), but for a navigation to another
document started from another origin. The document that leaves gets `beforeunload`, then `pagehide` and `unload`, and starts no
navigation while they run. A 204, a 205 or an attachment leaves the document as it is.

The tab's history is one for its frames and itself, HTML's joint session history (`src/page/history_joint.odin`). The tab's session
(its tree, `history.odin`) keeps, beside its entries, the steps of its frames: a push in a frame (another document, a fragment,
`pushState`, an intercepted navigation) is a step, filed after the entry of the tab that was current then, with the entry it made
current in the frame's session and the one it left. Flat arrays (`Session_History.steps`, `#soa`), navigables named by id: the web
sees one line, each entry of the tab followed by its steps.

- `history.length` in any document of the tab counts that line;
- `history.go(delta)`, `back()`, `forward()` in any document, and the browser's back and forward buttons, move `delta` positions:
  each frame then shows the entry of its last step at or before the position (before its first step, the entry that step left),
  traversed in its document or loaded again, and the tab its entry there: one of its own document's (popstate), or another
  document, which the shell loads (its frames start from their attributes, unless it comes from the back/forward cache);
- `navigation.traverseTo()` (`back()`, `forward()`) in a frame goes to the nearest position where that frame shows the entry;
- a push drops the positions ahead, a frame's push the tab's entries ahead too (another branch of the tree, `History_Entry.cut`),
  and the documents whose entries went get their `dispose` events;
- a sandboxed document's traversal moves nothing when it would move a navigable it may not navigate (its `navigation.traverseTo()`
  rejects with a `SecurityError`);
- a step of a frame that is gone (removed, or its document left) no longer counts.

What is not there:

- **a frame's entries after its document is loaded again**: going back to a document of the tab that is not in the back/forward cache
  loads its frames from their attributes, where HTML would show each frame's entry of that position;
- **a Window kept for a window that `window.open` made**: only a frame's initial about:blank keeps its `Window` (above);
- **`precommitHandler`** of `NavigateEvent.intercept()`.

## Windows that scripts open

`window.open()` to `_blank` or to a name nothing has, and a script's click on a link to one, open a window: a top-level navigable
of the same kind (`src/page/auxiliary.odin`), whose embedder makes the window around it (the browser a tab, the WPT runner's
headless host a window without a shell) and whose first document is the initial about:blank the page package makes (the
opener's origin, or an opaque one under `noopener`). The window keeps its id across its documents, so the `WindowProxy` that
`window.open` returned still names it after it navigated.

- **The opener.** `window.opener`, a name the opener's group finds (`window.open(url, name)`, a link's target), `postMessage`
  both ways, the DOM of a same-origin popup (its handles are looked up among the documents of the caller's browsing context
  group: its tab and the windows related to it by openers). `noopener` / `noreferrer` (features, or `rel`; a link to `_blank`
  has no opener unless `rel=opener`) open a window of its own group, and `window.open` returns null. `window.opener = null` ends it.
- **Closing.** `close()` closes a window a script opened: `closed` is true at once, the embedder closes it in a task. A tab the user
  opened stays open.
- **Cross-Origin-Opener-Policy.** A top-level document's policy is matched with that of the document it replaces (an initial
  about:blank has its opener's, when the opener is same origin with its top-level document): a mismatch puts the window in a new
  browsing context group. It gets a new id, so the opener's `WindowProxy` sees it closed; its `opener` is null, its name cleared,
  and the windows it opened lose theirs. `same-origin-allow-popups` keeps the popups it opens that have no policy.

Not there: a redirect's own policy (only the final response's counts), reports (`report-to`, `Report-Only`), sandboxed popups
inheriting their opener's sandbox, the window features (sizes, `popup`), and the browser's `noreferrer` (its navigations send
the Referer; the WPT runner's do not).

## Cost

A page without frames pays two comparisons per handle argument of an import call, and one load per call. The tag replaces bits of
the generation: `pool_get` compares what it compared. A slot reused 65536 times is retired rather than wrapped.
