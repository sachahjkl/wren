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
`MutationObserver` follows other documents with a browser object in each.

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

## Globals: a value bridge

`frame.contentWindow.foo` and `parent.foo()` go through `native/js/odin/frames_bridge.odin` and `web_bridge.js`. A request is
bytes the browser carries from an instance to another (`Frame_bridge`, which checks the origin each time):

| value | in the other realm |
|---|---|
| undefined, null, booleans, numbers, strings, bigints | copied |
| well-known symbols | by name; any other symbol is not carried |
| a DOM node | that realm's wrapper of the node |
| a window | that realm's `WindowProxy`, or its global |
| a built-in, an interface, their prototypes | by name: that realm's own (what a window gives for them is the reader's) |
| any other object, a function | a `Proxy` forwarding get, set, has, delete, keys, descriptors, prototype, call, construct |

An object coming home is itself. A realm that is gone answers `undefined`. Proxies are collected with `FinalizationRegistry`, which
releases the object in its realm.

A listener or a handler that is a `Proxy` of another realm's function runs as a callback of that realm: what it throws is reported at
that window's `error` event, and once that realm is gone it is not called.

What it is not is one heap:

- since `w.Array` is the reader's `Array`, an object of another window reaches the reader's prototypes: `x instanceof w.Promise` and
  `x.constructor === w.Object` hold, and so does `x instanceof Array`, where a browser says false;
- an object made with `new w.Object` is the caller's, so a listener made that way is the caller's too: what it throws goes to the caller's
  window (`dom/events/EventListener-handleEvent-cross-realm.html`);
- a native function refuses a `Proxy` for one of its own objects: a typed array or a `Blob` of one realm passed to a native of
  another throws a `TypeError`. An `Event` to `otherWindow.dispatchEvent` is handled, and `frameDocument.createRange()` and
  `getSelection()` give the frame's own, which its `Selection` takes;
- a cycle between two realms (a listener of one kept by the other) lives until one of them goes;
- ECMAScript built-ins and interface objects read from another window are the caller's own: `frame.contentWindow.Array === Array`, and
  `new frame.contentWindow.HTMLElement` makes one of the caller's. A DOM wrapper's prototype is its realm's too:
  `contentDocument.body instanceof HTMLElement` is true, where a browser says false. `navigator`, `screen`, `crypto`
  and `console` of another window are the caller's as well.

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

What is not there:

- **joint session history.** Each frame has its own: `history.back()` in the tab does not go back in a frame, a traversal moves one
  frame, and a push in a frame does not prune another's forward entries. The browser's back button leaves the tab's document;
- **a Window kept from the initial about:blank.** HTML keeps the `Window` when a frame goes from its initial about:blank to a document
  of the same origin. Here every document has an instance of its own, so what a script put on a blank frame's window
  (`frame.contentWindow.navigation.onnavigate = ...`, `window[0].foo = ...`) goes with that document;
- **`precommitHandler`** of `NavigateEvent.intercept()`.

## Cost

A page without frames pays two comparisons per handle argument of an import call, and one load per call. The tag replaces bits of
the generation: `pool_get` compares what it compared. A slot reused 65536 times is retired rather than wrapped.
