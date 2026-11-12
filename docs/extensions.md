# Browser extensions

This page is the plan for WebExtensions in Wren. Phases 1 and 2 are written, phase 3 for its most part (section 4,
"Status of phase 1", "Status of phase 2" and "Status of phase 3"). The first target
is Bitwarden's browser extension (`bitwarden/clients`, `apps/browser`), Manifest V3, Chrome build first, Firefox build
second.

Terms used on this page, one per concept:

- **extension**: one installed WebExtension package.
- **flavour**: `chrome` or `firefox`. The flavour decides the URL scheme, the namespaces and the background type.
- **extension origin**: the origin of an extension's own documents (`chrome-extension://<id>` or `moz-extension://<uuid>`).
- **extension page**: a document with the extension origin (popup, options page, offscreen document, a tab).
- **background**: the extension's event context. A service worker (Chrome flavour) or an event page (Firefox flavour).
- **world**: one JavaScript realm of a document. The **main world** runs the page's scripts. An **isolated world**
  runs the content scripts of one extension.
- **extension context**: a realm that has extension APIs: the background, an extension page, an isolated world.
- **router**: the object on the loop thread that carries API calls, events, messages and ports between extension contexts.

## 1. Scope and non-goals

In scope:

- Manifest V3 only.
- Install from an unpacked directory, a `.zip` file or a `.crx` file (CRX3). The user chooses the file or the directory.
- The `chrome.*` namespace with promises and callbacks. The `browser.*` namespace with promises for the Firefox flavour.
- A background service worker (Chrome flavour) and a background event page (Firefox flavour).
- Content scripts and CSS in isolated worlds. Programmatic injection (`scripting`).
- Extension pages: popup, options page, tab, offscreen document.
- Shell UI: toolbar action button with badge, popup panel, `about:extensions`, commands, context menus, permission prompts.
- The API set of section 2. An API outside this set does not exist: `chrome.<name>` is `undefined`.

Non-goals of the first phases:

- No install from the Chrome Web Store or from addons.mozilla.org. No automatic update.
- No Manifest V2 (`browser_action`, persistent background pages, blocking `webRequest` for all requests).
- No native messaging (`runtime.connectNative`). Bitwarden uses it only for biometric unlock with the desktop application.
- No `declarativeNetRequest`. Wren's content blocker stays the only request filter.
- No `sidePanel` (Chrome) and no `sidebar_action` (Firefox). The manifest keys are parsed and ignored.
- No `privacy` API. Bitwarden requests it as an optional permission; the request is refused.
- No `devtools.*`, `debugger`, `proxy`, `downloads`, `cookies`, `history`, `bookmarks`, `identity`, `management`
  (except `management.getSelf`).
- No messages between two extensions (`onMessageExternal`, `externally_connectable`).
- No extension service worker `fetch` event for the extension's own pages.
- No `storage.sync` to a server. `storage.sync` is a local area. `storage.managed` is an empty area.
- No signature check of a `.crx` file against a store. The file is treated as an unpacked package from the user.

## 2. What Bitwarden needs

Source: `apps/browser/src/manifest.v3.json`, `webpack.base.js` and the TypeScript sources of `apps/browser/src`
(read 2026-11-12, version 2026.11.0). The build removes the keys of other browsers (`__firefox__`, `__chrome__`,
`__safari__`, `__opera__` prefixes).

### 2.1 Manifest keys

| Key | Chrome build | Firefox build | Wren |
|---|---|---|---|
| `manifest_version`, `name`, `short_name`, `version`, `description`, `author`, `homepage_url`, `icons` | yes | yes | parse |
| `default_locale: "en"`, `_locales/`, `__MSG_*__` in the manifest | yes | yes | i18n catalogue |
| `minimum_chrome_version: "134.0"` | yes | no | compare with the Chrome version in Wren's user agent |
| `browser_specific_settings.gecko.id`, `strict_min_version` | no | yes | marks the Firefox flavour, gives the id |
| `background.service_worker: "background.js"` | yes | no | background service worker |
| `background.scripts: ["background.js"]` | no | yes | background event page |
| `action` (`default_icon`, `default_title`, `default_popup: "popup/index.html"`) | yes | yes | toolbar button, popup |
| `content_scripts` (2 entries, below) | yes | yes | isolated worlds |
| `permissions`, `optional_permissions`, `host_permissions` | yes | yes | permission model |
| `content_security_policy.extension_pages`: `script-src 'self' 'wasm-unsafe-eval'; object-src 'self'` | yes | yes | CSP of extension pages |
| `content_security_policy.sandbox`, `sandbox.pages` (`overlay/menu-button.html`, `overlay/menu-list.html`) | yes | no | opaque origin, no extension API |
| `commands` (below) | yes | yes | shortcuts |
| `web_accessible_resources` (1 entry, `matches: ["<all_urls>"]`, `use_dynamic_url: true`) | yes | yes | access rule of the scheme |
| `storage.managed_schema` | yes | no | ignore |
| `side_panel`, `sidebar_action` | yes | yes | ignore |

Content script entries, both with `matches: ["*://*/*", "file:///*"]`, `exclude_matches: ["*://*/*.xml*", "file:///*.xml*"]`,
`run_at: "document_start"`:

1. `content/content-message-handler.js`, `all_frames: false`.
2. `content/trigger-autofill-script-injection.js` with `content/autofill.css`, `all_frames: true`. The script sends one
   message (`triggerAutofillScriptInjection`). The background then injects the real autofill scripts with
   `scripting.executeScript`.

Commands: `_execute_action` (Ctrl+Shift+Y; Linux Ctrl+Shift+U), `autofill_login` (Ctrl+Shift+L), `generate_password`
(Ctrl+Shift+9), `autofill_card`, `autofill_identity`, `lock_vault` (no default key).

Permissions (Chrome build): `activeTab`, `alarms`, `clipboardRead`, `clipboardWrite`, `contextMenus`, `idle`,
`offscreen`, `scripting`, `sidePanel`, `storage`, `tabs`, `unlimitedStorage`, `webNavigation`, `webRequest`,
`webRequestAuthProvider`, `notifications`. The Firefox build has the same list without `offscreen` and `sidePanel`.
Optional: `nativeMessaging`, `privacy`. Host permissions: `https://*/*`, `http://*/*`.

### 2.2 APIs and events, by user flow

`P` = popup and other extension pages, `B` = background, `C` = content script (isolated world).

| Flow | APIs and events | Contexts |
|---|---|---|
| **Start** (the extension loads, the popup shows the login screen) | `runtime.getManifest`, `runtime.id`, `runtime.getURL`, `runtime.getPlatformInfo`, `runtime.onInstalled`, `runtime.lastError`, `runtime.getContexts`, `runtime.reload`, `extension.getViews` and `extension.getBackgroundPage` (may be `undefined`), `i18n.getMessage`, `i18n.getUILanguage`, `management.getSelf`, `storage.local` (`get`, `set`, `remove`, `clear`), `storage.session` (same), `storage.managed.get`, `storage.onChanged`, `runtime.sendMessage`, `runtime.onMessage`, `runtime.connect`, `runtime.onConnect`, `Port` (`postMessage`, `onMessage`, `onDisconnect`, `disconnect`, `sender`), `action.setIcon`, `action.setBadgeText`, `action.setBadgeBackgroundColor`, `action.setTitle`, `action.setPopup`, `tabs.query`, `tabs.get`, `tabs.getCurrent`, `windows.getCurrent`, `windows.getAll`, `permissions.contains`, `alarms.create`, `alarms.get`, `alarms.clear`, `alarms.clearAll`, `alarms.onAlarm` | P, B |
| **Log in and unlock** | The Start set. Web platform in the extension origin: `fetch` to the server with host permissions and no CORS check, `crypto.subtle`, WebAssembly (the Bitwarden SDK, `asyncWebAssembly`), `indexedDB`, `localStorage` and `sessionStorage` (pages only), `Worker`, dynamic `import()`. `idle.queryState`, `idle.setDetectionInterval`, `idle.onStateChanged` for the vault timeout. `offscreen.createDocument`, `hasDocument`, `closeDocument` with reasons `CLIPBOARD` and `LOCAL_STORAGE` (Chrome build). `tabs.create` (open the web vault, the two-step login page). `windows.create({type: "popup"})`, `windows.update`, `windows.remove`, `windows.get`, `windows.onFocusChanged`, `windows.onRemoved`, `windows.onCreated` for the popout window | P, B |
| **Autofill a login form** | Static content scripts. `scripting.executeScript` (`files`, `func`, `target` with `tabId`, `frameIds`, `allFrames`; `world` `ISOLATED` and `MAIN`; `injectImmediately`), `scripting.insertCSS`, `scripting.registerContentScripts`, `unregisterContentScripts`. `tabs.sendMessage` (with `frameId`), `runtime.sendMessage`, `runtime.connect` from C. `tabs.onActivated`, `onUpdated`, `onRemoved`, `onCreated`, `onReplaced`, `onAttached`, `onDetached`. `webNavigation.getFrame`, `getAllFrames`, `onCommitted`, `onCompleted`, `onErrorOccurred`. `dom.openOrClosedShadowRoot` (C). `tabs.captureVisibleTab`. In the page: `MutationObserver`, `IntersectionObserver`, `ResizeObserver`, `TreeWalker`, `attachShadow({mode: "closed"})`, `customElements?.define` (optional), `popover` and `showPopover()`, `requestIdleCallback`, `elementFromPoint`, `getComputedStyle`, `window.postMessage`, `MessageChannel`. Frames of `web_accessible_resources` in the page: `overlay/menu.html`, `overlay/menu-button.html`, `overlay/menu-list.html`, `notification/bar.html` | B, C |
| **Save or update a login** (notification bar) | The Autofill set. `webRequest.onBeforeRequest`, `onBeforeRedirect`, `onCompleted`, `onErrorOccurred` (observe only, no `blocking`) | B, C |
| **Context menu** | `contextMenus.create`, `remove`, `removeAll`, `onClicked` (contexts `all`, `page`, `editable`, `password`, `selection`, `frame`...; parents and separators). `tabs.sendMessage` to `content/contextMenuHandler.js` | B, C |
| **Keyboard shortcuts** | `commands.onCommand`, `commands.getAll`, `_execute_action` opens the popup, `action.openPopup` | B |
| **Copy a password, clear the clipboard later** | `navigator.clipboard.writeText` and `readText` in P and in the offscreen document; `document.execCommand("copy")` as the older path; `alarms` for the clear | P, B |
| **HTTP authentication** | `webRequest.onAuthRequired` with `asyncBlocking` (Chrome) or `blocking` with a promise (Firefox), `webRequest.onCompleted`, `onErrorOccurred` | B |
| **Passkeys** | `scripting.executeScript` with `world: "MAIN"` (`content/fido2-page-script.js`), `window.postMessage` and `MessageChannel` between the two worlds, `webRequest.onHeadersReceived` (reads `Permissions-Policy`), `navigator.credentials` replaced in the main world | B, C |
| **Notifications** | `notifications.create`, `clear`, `onClicked`, `onButtonClicked` | B |
| **Skipped** | `runtime.connectNative`, `privacy.services.*`, `sidePanel.*`, `sidebarAction.*`, `permissions.request` for `nativeMessaging` and `privacy` (answers `false`), `permissions.onAdded` | |

Bitwarden reads `navigator.userAgent` to choose its browser type. The Chrome build needs ` Chrome/` in the user agent
and `typeof browser === "undefined"`. The Firefox build needs ` Firefox/` or `typeof browser !== "undefined"`.
Wren's user agent contains `Chrome/148.0.0.0` (`src/net/settings.odin`): the Chrome build detects Chrome, and
`minimum_chrome_version` 134 passes.

## 3. Architecture

### 3.1 Packages

| Package or files | Content | Depends on |
|---|---|---|
| `src/extensions` (new, portable, no shell, no page) | manifest, match patterns, ids, package readers, i18n catalogue, permission model, storage areas, the registry, the data model of alarms, commands and context menus | `base`, `url`, `config`, `csp` |
| `src/fetch/extension_scheme.odin` | the scheme hop and its access rule | `extensions` |
| `src/page/ext_*.odin` | worlds, content script injection, the router, the API implementations, the background host | `extensions`, `fetch` |
| `native/js/odin/ext_*.odin` | the namespaces in the engine | generated glue |
| `src/browser/ext_*.odin` | toolbar buttons, popup, `about:extensions`, prompts, commands, context menus | `page`, `extensions`, toolkit |
| `api/ext.widl`, `api/ext_<namespace>.widl` | the transport and the API description | bindgen |

The engine of the content blocker (`src/adblock`) is independent of the shell for the same reason: `src/extensions`
has unit tests without a browser.

### 3.2 Registry and profile storage

The registry is one field of `page.Pages` (`Pages.extensions`), because every page and worker of the App reads it.
The App owns it. It is not a global.

One `Extension` record holds:

- `id`, `flavour`, `version`, `enabled`, the install source (directory, zip, crx) and its path;
- an **image**: the parsed manifest, the i18n catalogue, the file index and the compiled match patterns. The image is
  immutable and reference-counted. Worker threads read it without a lock. A reload makes a new image;
- the granted permissions and the granted host patterns;
- the runtime state on the loop thread: the background host, the action state per tab, the context menu items, the
  alarms, the registered content scripts, the open ports.

Profile files (written through `Profile_File`, `src/browser/profile_writes.odin`):

```
<profile>/extensions.txt                 the list: id, flavour, source, path, enabled, grants, command keys
<profile>/extensions/<id>/package/       the files of a zip or crx install (an unpacked install reads its own directory)
<profile>/extensions/<id>/storage/       local, sync: one store per area (src/idb's file engine: journal, checkpoint)
<profile>/extensions/<id>/state.txt      alarms, context menu items, registered content scripts, the events the background listens to
```

`storage.session` is kept in memory by the registry. It is lost when the browser exits or the extension reloads.
The web storage of the extension origin (IndexedDB, `localStorage`, Cache API) goes in the profile's normal stores,
keyed by the extension origin. Removing an extension removes its directory and its origin's site data.

**Extension id.**

- Chrome flavour with a `key` in the manifest or a CRX3 public key: the first 16 bytes of the SHA-256 of the DER key,
  each nibble as a letter `a` to `p`.
- Chrome flavour, unpacked without `key`: the same encoding of the SHA-256 of the absolute directory path.
- Firefox flavour: `browser_specific_settings.gecko.id` identifies the extension. The origin host is a random UUID made
  at install and kept in `extensions.txt`.

**Flavour.** `browser_specific_settings.gecko` present and no `background.service_worker`: `firefox`. Otherwise `chrome`.

### 3.3 Manifest parsing and validation

`src/extensions/manifest.odin` parses the JSON (comments allowed, as Chrome allows them) into a typed `Manifest`.

- An unknown key gives a warning in `about:extensions`. It is not an error.
- A wrong type for a known key is an error. The extension does not load.
- `manifest_version` other than 3 is an error.
- A permission that Wren does not implement gives a warning. Its namespace is absent.
- `__MSG_name__` strings are replaced from the catalogue of the UI language, then `default_locale`.
- Every file the manifest names must exist in the package and stay inside it.
- Match patterns (`<all_urls>`, `*://*/*`, `https://*.example.com/*`, `file:///*`) compile to one matcher
  (`match_pattern.odin`). The same matcher serves `content_scripts`, `host_permissions`, `web_accessible_resources`,
  `webRequest` filters and `tabs.query({url})`.
- Limits, each a preference (`extensions.manifest.max_bytes`, `extensions.package.max_files`,
  `extensions.package.max_bytes`, `extensions.content_scripts.max_entries`).

Package readers: a directory is read in place. A `.zip` is unpacked into `package/`. A `.crx` is a CRX3 header followed
by a zip; the reader takes the public key from the header and unpacks the zip. An entry with `..`, an absolute path or
a symbolic link is refused.

### 3.4 The scheme, its origin, CSP and web-accessible resources

`fetch/loader.odin` chooses a hop by scheme. Two more schemes go to `extension_hop` (`src/fetch/extension_scheme.odin`):
`chrome-extension` and `moz-extension`. The loader gets the registry through an interface of `fetch`, as it gets the
content blocker (`Interceptor`): `fetch` does not import `page`.

- **Origin.** A tuple origin: scheme, host = id or UUID, no port. It is a secure context (`url.is_potentially_trustworthy`).
  `document.cookie` is empty. Storage is keyed by this origin.
- **Lookup.** The path is percent-decoded and normalised. A path that leaves the package fails. The file is read on the
  blocking pool, never on the loop thread. The MIME type comes from the file extension. Responses are not stored in the
  HTTP cache.
- **Who may load a URL of extension E.** One function, `extension_may_load(initiator, target)`:
  1. the initiator has E's origin: yes;
  2. the navigation comes from the address bar, a bookmark or the shell: yes;
  3. the path matches a `web_accessible_resources` entry and the initiator's URL matches that entry's `matches`: yes;
  4. otherwise: a network error, the same error as an absent extension. A page cannot tell "refused" from "not installed".
- **`use_dynamic_url`.** Phase 6. The URL host is then a UUID made for the session, not the id.
- **CSP of extension pages.** The response carries the manifest's `extension_pages` policy, or the default
  `script-src 'self' 'wasm-unsafe-eval'; object-src 'self'`. Wren refuses a manifest policy that allows a remote script
  source, `'unsafe-eval'` or `'unsafe-inline'` for scripts. The same policy applies to the background service worker
  (`Sw_Version.csp`). `src/csp` already knows `'wasm-unsafe-eval'`.
- **Sandbox pages.** A document listed in `sandbox.pages` gets an opaque origin, the `sandbox` policy and no extension API.
- **Requests from the extension origin.** In `fetch`'s CORS step, a request whose initiator has an extension origin and
  whose target matches a granted host pattern is same-origin for CORS: no preflight, the response is readable. Cookies
  follow the normal rules for a cross-site request. A target without a grant gets normal CORS.

### 3.5 The background

**Chrome flavour: a service worker.** `page/service_worker.odin` keeps registrations, runs each version as a JavaScript
worker hosted by a page that shows nothing, starts it for an event and stops it after `service_workers.idle_ms`. An
extension reuses this with four differences, in `src/page/ext_background.odin`:

1. The registry creates the registration when the extension is enabled. The scope is the extension origin. No script
   calls `register()`. The registration is not written in `service_workers.txt`: it is derived from `extensions.txt`.
2. The script comes from the image (`Sw_Version.image`). There is no update check and no waiting state. A new
   version exists only after a reload of the extension.
3. The loader does not offer requests to it (no `fetch` event, section 1). `install` and `activate` are sent once.
4. The worker's realm gets the extension APIs (section 3.9). Its API calls are requests to the loop thread, in the form
   service workers already use (`Sw_Reply_Kind.Request` answered by `Sw_Event_Kind.Answer`).

Lifecycle. The router keeps a queue of events per extension. An event for a stopped background starts it. The worker
stops after `extensions.background.idle_ms` (default 30000) with no pending event, no pending API call and no open
port. Listeners must be added during the first run of the script. After that run, the router stores the names of the
events with a listener (`state.txt`). A later event with no stored listener does not start the worker.
`runtime.onInstalled` fires after install, update and reload. `runtime.onStartup` fires at browser start.

**Firefox flavour: an event page.** A page with the extension origin that shows nothing, with `background.scripts`
loaded in order as classic scripts. It uses the same host as offscreen documents (section 3.8) and the same idle rule.
It has a DOM, so the Firefox build needs no offscreen document.

### 3.6 Content scripts and isolated worlds

**What exists.** A `Page` already holds several Wasm instances that share its DOM (`Page.instances`). Each call knows
its instance (`Call.owner`). Listeners and timers record their owner instance and are called back in it. A wrapper
belongs to one realm and pins its node; a node has one wrapper per realm (`docs/frames.md`). So an isolated world is
one more engine instance on the same `Page`, with the same handle tag: no call is routed, no value bridge is used.

**The new object.** `Page.worlds: [dynamic]^World` (`src/page/ext_worlds.odin`). A `World` holds its `Js_Realm`, its
instance index and its extension id. World 0 is the main world (`Page.js` today). A page has at most one isolated world
per extension. All content scripts of that extension in that document share it. A world is created on first need and
closes with the page's scope.

**What must be split by world.** Each item below is keyed by the owner instance today or must become so:

| State | Rule |
|---|---|
| Global object, built-ins, prototypes | per world (free: another engine instance) |
| Wrappers and their own properties | per world (free). A property set by a content script is not visible to the page |
| Event listeners (`addEventListener`) | per world (`Listener.owner`). Dispatch order follows registration order across worlds |
| Event objects | one host event, one wrapper per world (`js_events_host.odin` already has the case of another realm) |
| Event handler attributes and `on*` properties | the attribute's handler compiles and runs in the main world only. Each world has its own `on*` slot |
| Timers, promises, microtasks | per world. The page's microtask checkpoint drains every world's job queue |
| `MutationObserver`, `IntersectionObserver`, `ResizeObserver` | per world: the observer state in `Js_Dom_State` gets an owner |
| Custom element registry | the main world only. In an isolated world `customElements` is `null`, as in Chrome. Reactions run in the main world |
| `window.postMessage`, `MessageChannel` | the `message` event goes to the listeners of every world. Each world deserialises its own copy |
| `CustomEvent.detail`, `event.data` of script-made events | copied by structured clone into the other world; `null` if it cannot be cloned |
| Inserted `<script>` elements, `javascript:` URLs, `document.write` | run in the main world, whichever world inserted them |
| `fetch`, `XMLHttpRequest`, `WebSocket` from an isolated world | use the page's Environment: the page's origin, CORS and cookies. No extension privilege |
| CSP | the page's CSP does not stop a content script from running or from adding inline styles. Requests it makes follow the page's CSP |
| `window.frames`, `parent`, `contentWindow` | give the isolated world of the same extension in the other document, or a cross-origin proxy if none exists |
| Storage (`localStorage`, `indexedDB`) | the page's origin |
| Slow-script limit, heap limit, call deadline | per world, the same preferences as a page |
| Collection | a wrapper of any world pins its node. The grouping of wrappers by tree (`js_realm.odin`) counts pins of other worlds as outside roots |

`scripting.executeScript({world: "MAIN"})` runs a file in world 0 with no extension API. It is the only way an
extension runs code in the main world, and it needs a host grant for the document.

**APIs in an isolated world.** `runtime` (`id`, `getURL`, `getManifest`, `sendMessage`, `connect`, `onMessage`,
`onConnect`, `lastError`), `i18n`, `storage`, `dom.openOrClosedShadowRoot`, `extension.inIncognitoContext`. Nothing else.

**Injection.** `src/page/ext_inject.odin`, called from the embedder's hooks of the page (`realm_started`, `adopted`,
`parsed`, and the load event):

- For each committed document, the registry gives the matching entries: static `content_scripts`, scripts registered
  with `scripting.registerContentScripts`, and pending `executeScript` calls. Matching uses the document URL,
  `matches`, `exclude_matches`, `include_globs`, `exclude_globs`, `all_frames`, `match_about_blank`,
  `match_origin_as_fallback`, and the host grants.
- `run_at: document_start`: after the document element exists, before any script of the page. `document_end`: at
  `parsed`. `document_idle` (the default): after `document_end`, at the load event or 200 ms after `parsed`, whichever
  comes first.
- Script files of one entry run in manifest order, as classic scripts, with the bytecode cache.
- CSS files are added as author-origin style sheets of the document before the first style pass of `document_start`.
  `scripting.insertCSS` adds one later; `removeCSS` removes it. The page's scripts do not see these sheets in
  `document.styleSheets`.
- No injection in: extension pages of another extension, `about:` pages of Wren, `view-source:`, the documents of
  Wren's own UI, and hosts in `extensions.restricted_hosts`.
- A document whose site has JavaScript switched off still gets content scripts. The switch is about the page's scripts.

### 3.7 The router: messages, ports, events, API calls

The router (`src/page/ext_router.odin`) lives on the loop thread and belongs to the registry. Every extension context
registers with it: `{extension, kind (background, popup, tab, options, offscreen, content), page, world, tab id, frame
id, document id, url, origin}`. This record is the `MessageSender` and the answer of `runtime.getContexts`. The router
fills it; a context cannot forge it.

- **API call.** A context sends `(method id, call id, JSON arguments)`. The router checks the context kind and the
  permission, decodes the arguments, runs the implementation on the loop thread, and answers `(call id, result or
  error)`. A page realm calls directly. A worker realm sends the call through its worker link.
- **Event.** An implementation calls `ext_emit(extension, event id, JSON arguments, filter)`. The router delivers to
  each context with a listener for that event. A stopped background starts first.
- **`runtime.sendMessage`.** Goes to every extension page and the background of the same extension, not to the sender
  and not to content scripts. **`tabs.sendMessage`** goes to the isolated worlds of that extension in the tab (one frame
  with `frameId`, else all frames). The first listener that calls `sendResponse`, returns `true` then calls it, or
  returns a promise, gives the answer. With no receiver, the caller gets the error "Could not establish connection.
  Receiving end does not exist."
- **Ports.** `runtime.connect` and `tabs.connect` make a port pair in the router. Each end is an id. `postMessage`
  keeps order. `disconnect`, the close of a page or a world, or the stop of the background fires `onDisconnect` at the
  other end. An open port keeps the background alive for `extensions.background.port_keepalive_ms` after its last message.
- **Payloads.** Messages are JSON text, as in Chrome. The Firefox flavour uses structured clone (phase 7).
- **Limits**, each a preference: `extensions.message.max_bytes` (default 64 MiB), `extensions.ports.max_per_extension`,
  `extensions.events.max_queued`, `extensions.calls.max_pending`. Past a limit, the call fails with an error; nothing
  is dropped silently.
- **Lifetime.** Contexts, ports and pending calls are registered in the scope of their page or worker. `scope_close`
  removes them. A late answer for a closed context is dropped (handles, rule 2 of `architecture.md`).

Tab, window and frame ids: `Tab.id` and the window's id are already unique in the process. They are mapped to small
integers for the API. The top frame is 0. A subframe's id comes from its `Navigable` id. `documentId` is a random
string per document.

### 3.8 Extension pages

An extension page is a normal `Page` whose URL has the extension origin. Its main world gets the full extension API
because its origin equals the extension's. An extension frame inside a web page (Bitwarden's `overlay/menu.html`) is
the same case: the check is the document's origin, not where it is shown.

- **Tab and options page.** A normal tab. `runtime.openOptionsPage` opens `options_ui.page` or `options_page`.
- **Popup** (`ext_popup.odin`). A tab of no window, loaded by `navigate`, shown through a page view (`page_view.odin`,
  the same view a frame's document has) in a toolkit popover under the action button. Its size follows the document's
  content, between 25 x 25 and 800 x 600 CSS pixels: each layout measures the root element's and the body's boxes and
  what overflows, the next frame lays it out at that size; it is fitted again for a few frames after each change of the
  document, never more. It has the keyboard while it is open, and the pointer over it. It closes on Escape, on a press
  outside it, on a second click on its button, on `window.close()` and when its window shows another tab. Closing it
  closes its tab and its page scope. Context kind: `popup`.
- **Offscreen document** (`offscreen.createDocument`). A page that shows nothing, hosted like the page that hosts a
  service worker. One per extension. APIs: `runtime` only, as in Chrome. It closes with `closeDocument`, or with the
  extension. `extensions.offscreen.max_lifetime_ms` bounds a document whose only reason is `CLIPBOARD`.
- **Popout window** (`windows.create({type: "popup"})`). A Wren window with one tab and no tab strip, toolbar or address
  bar. It shows the extension's name and the document title in its title bar.

### 3.9 API surface: one description, everything generated

The rule of `architecture.md` holds: an API starts in `api/`.

**Transport: `api/ext.widl`**, a normal module with generated trampolines and conformance cases:

```
Ext_info            the context: extension id, flavour, kind, base URL (read once at realm start)
Ext_manifest        the manifest as JSON
Ext_message         i18n: one message by name (the image's catalogue; no loop thread needed)
Ext_call            (method id, JSON) -> Promise<JSON>
Ext_listen          (event id, on/off, filter JSON): tells the router that a listener exists
Ext_eventNext, Ext_eventTake, Ext_eventDone    the next event for this realm, its payload
Ext_respond         the answer to an event that expects one (sendResponse, onAuthRequired)
Ext_portPost, Ext_portClose
Dom_openOrClosedShadowRoot    (the only extension API that takes a node handle)
```

These imports are linked only into a realm that is an extension context. A page's main world does not have them.

**Description: `api/ext_<namespace>.widl`** (`ext_runtime.widl`, `ext_tabs.widl`, `ext_storage.widl`...). The dialect
gains three things: `[Permission=tabs]`, `[Contexts=(Background, Page, Content)]`, and `event` declarations. Structs,
enums and optional members describe the JSON shapes. `bindgen` generates:

- `src/page/ext_api_generated.odin`: the method table (id, name, permission, contexts), the JSON decoder of each
  method's arguments into an Odin struct with type and range checks, the encoder of its result, and the expected
  prototype of the implementation `ext_<namespace>_<method>(c: ^Ext_Call, args: ...) -> (result, Ext_Error)`. A missing
  or mistyped implementation does not compile. Implementations are in `src/page/ext_api_<namespace>.odin`; those that
  need the shell call through a table of procedures the shell fills (`Ext_Embedder`, as `Sw_Embedder`).
- `native/js/odin/ext_gen.odin`: the namespace objects built at realm start, the argument normalisation, and the
  event objects (`addListener`, `removeListener`, `hasListener`).
- `docs/api/ext/`: the reference, with the support status of each method.
- conformance cases: wrong types, missing fields, an absent permission, a wrong context, oversized payloads, for every method.

**Calling conventions**, written once in `native/js/odin/ext_runtime.odin`:

- `chrome.*`: a method returns a promise. If the last argument is a function, the method calls it with the result and
  returns `undefined`. On an error, `chrome.runtime.lastError` is set during the callback; an unread `lastError` logs
  "Unchecked runtime.lastError". Without a callback, the promise rejects with an `Error`.
- `browser.*`: exists only in the Firefox flavour. Promises only. `chrome` exists there too, with callbacks.
- A namespace exists only if the image's permissions include it and the context kind allows it. Synchronous members
  (`runtime.id`, `getURL`, `getManifest`, `i18n.getMessage`, `i18n.getUILanguage`) answer from the image without the router.

### 3.10 Shell UI

All in `src/browser/ext_*.odin`, built with the toolkit, driven through the command registry.

- **Action button** (`ext_toolbar.odin`). One button per enabled extension with an `action`, after the content
  blocker's icon in `address_row`. It shows the icon (per tab, `action.setIcon` with a path or `ImageData`), a badge
  (text of at most 4 characters, background colour), and a tooltip (the title). A click opens the popup, or fires
  `action.onClicked` when no popup is set. A right click opens a menu: options, manage, remove. More buttons than
  `browser.extensions.toolbar.max_buttons` go into an overflow menu.
- **Popup panel** (`ext_popup.odin`): section 3.8.
- **`about:extensions`** (`ext_page.odin`): the list with name, version, id, flavour, warnings and errors of the
  manifest; enable, reload, remove; "Load unpacked", "Install from file"; the granted permissions and hosts with a
  switch per host pattern; the shortcut of each command; the state of the background and a link to its console.
- **Commands** (`ext_commands.odin`). Each manifest command becomes a `Command` named `extension.<id>.<name>`, in the
  category "Extensions", with the suggested key if no command of Wren and no other extension has it. The user changes
  keys in `about:extensions`. The command fires `commands.onCommand`; `_execute_action` opens the popup. The palette
  lists them.
- **Context menus** (`ext_context_menu.odin`). The registry keeps a tree of items per extension. `context_menu.odin`
  asks it for the items that match the `Context_Request` (contexts, `documentUrlPatterns`, `targetUrlPatterns`). One
  extension with more than one top-level item gets a submenu with its name and icon. A click fires
  `contextMenus.onClicked` with `OnClickData` and grants `activeTab`.
- **Prompts** (`ext_prompts.odin`). Install shows the name, the permissions and the host patterns in plain words;
  the user accepts or cancels. `permissions.request` shows the added items and needs a recent user action.
- **Notifications**: `notification_shell.odin` already shows system notifications; `notifications.create` uses it.
- **Developer tools**: the background and each extension page are targets of the tools and of `wren ctl`.

### 3.11 Permissions and security model

The extension is a third principal, between the browser and a page. The rules:

1. **An extension is a guest.** Every realm of an extension is a Wasm instance with the limits of any guest: the
   sandbox, the memory cap, the call deadline, the slow-script stop. A trap loses the realm, never the browser.
2. **One gate.** Every API call passes `ext_call_allowed(context, method)` in the router: the extension is enabled, the
   context kind is allowed, the permission is granted. Every access to a tab or a URL passes
   `ext_host_allowed(extension, url)`: a granted host pattern, or `activeTab` for that tab. There is no second path.
3. **The context is known by the host.** The router derives extension, kind, tab and frame from the instance that
   calls. A guest sends no identity.
4. **Host permissions are grants.** Install grants the manifest's `host_permissions` after the prompt. The user can
   withdraw one pattern in `about:extensions`. `optional_host_permissions` need `permissions.request`. Without a grant
   for a document: no content script, no `executeScript`, no `tabs.sendMessage` target, no `url` or `title` in a `Tab`,
   no `webRequest` event, CORS applies.
5. **`activeTab`.** A click on the action button, a command or a context menu item of the extension grants the current
   document's origin for that tab until it navigates to another origin or closes.
6. **Worlds are isolated.** A page script cannot read a content script's variables, wrappers or listeners, and the
   reverse holds. The two share the DOM tree only. Page scripts can see DOM changes; this is the WebExtensions model.
7. **No extension reaches another.** No message, no port, no storage, no file: `extension_may_load` answers the same
   error for another extension as for an absent one.
8. **A page reaches an extension only through `web_accessible_resources`.** A page has no `chrome.runtime`.
9. **Restricted documents.** No extension acts on Wren's own pages (`about:*`), the developer tools, `view-source:`,
   another extension's pages, or hosts in `extensions.restricted_hosts`. `tabs` data for these tabs has no URL.
10. **Secrets of the browser stay out.** No API gives cookies, history, saved form data, the profile path, or the
    files of the disk. `file:` documents get content scripts only with the switch "Allow access to file URLs" (off by default).
11. **Requests.** `webRequest` is an observer on `fetch.Loader` (`fetch/observe.odin`), filtered by host grants.
    It cannot block, redirect or change a request. The one exception is `onAuthRequired` with `webRequestAuthProvider`:
    the listener gives credentials for a 401 or 407 challenge, within `extensions.webrequest.auth_timeout_ms`; then the
    normal prompt shows.
12. **Private data in logs.** The router logs method names, never arguments, messages or storage values.
13. **Bounded resources, each a preference** in `src/extensions/settings.odin` and `src/page/ext_settings.odin`,
    registered in `src/browser/settings.odin`:

| Preference | Default | Reason |
|---|---|---|
| `extensions.enabled` | true | the whole subsystem off: no registry, no hook cost |
| `extensions.max_installed` | 64 | toolbar and per-document matching cost |
| `extensions.package.max_bytes`, `max_files` | 512 MiB, 20000 | a hostile archive |
| `extensions.background.idle_ms` | 30000 | Chrome's value |
| `extensions.background.max_heap_bytes` | as `javascript.max_heap_bytes` | Bitwarden's SDK and vault live there |
| `extensions.worlds.max_per_document` | 16 | one engine instance each |
| `extensions.storage.local.max_bytes` | 10 MiB; no limit with `unlimitedStorage` | Chrome's value |
| `extensions.storage.session.max_bytes` | 10 MiB | Chrome's value |
| `extensions.storage.sync.max_bytes`, `max_item_bytes`, `max_items` | 102400, 8192, 512 | Chrome's values |
| `extensions.message.max_bytes` | 64 MiB | Chrome's value |
| `extensions.alarms.min_period_ms`, `max_per_extension` | 30000, 500 | Chrome's values |
| `extensions.context_menus.max_items` | 1000 | menu build cost |
| `extensions.commands.max_per_extension` | 64 | palette and shortcut table |
| `extensions.scripting.max_registered` | 1000 | per-document matching cost |

## 4. Phases

Every phase ends with something a user can try. Every phase keeps the earlier phases working. Phases 1 to 6 use the
Chrome build of Bitwarden. Test fixtures are small extensions in `examples/extensions/<name>/`; Bitwarden itself is
never a test fixture (size, licence, network), it is checked by hand and by the measures of section 5.

### Phase 1: the popup opens and shows the login screen

Scope:

- `src/extensions`: `manifest.odin`, `match_pattern.odin`, `id.odin`, `package.odin` (directory only), `i18n.odin`,
  `registry.odin`, `settings.odin`.
- `src/fetch/extension_scheme.odin`: the hop, `extension_may_load` rules 1 and 2, the CSP of extension pages, the
  secure context, the CORS rule for granted hosts.
- `api/ext.widl`, the dialect additions in `src/tools/bindgen`, `api/ext_runtime.widl`, `ext_i18n.widl`,
  `ext_storage.widl`, `ext_tabs.widl` (`query`, `get`, `getCurrent`), `ext_windows.widl` (`getCurrent`, `getAll`),
  `ext_action.widl`, `ext_alarms.widl`, `ext_permissions.widl` (`contains`), `ext_management.widl` (`getSelf`),
  `ext_extension.widl` (`getViews`).
- `src/page`: `ext_router.odin` (calls, events, `sendMessage`, ports), `ext_background.odin` (service worker),
  `ext_api_*.odin`, `ext_storage.odin` (local, session, managed; `onChanged`), `ext_settings.odin`.
- `native/js/odin`: `ext_runtime.odin`, `ext_gen.odin`.
- `src/browser`: `ext_shell.odin` (start, stop, the embedder table), `ext_toolbar.odin` (icon, title, badge),
  `ext_popup.odin`, `ext_page.odin` (`about:extensions` with "Load unpacked", enable, reload, remove, errors).
- `changelog.d/`: one fragment. `docs/api/ext/` is generated.

The user can: open `about:extensions`, load the Bitwarden Chrome build from its directory, see its icon in the toolbar,
click it, see the login screen.

Tests:

- Unit, `src/extensions`: the manifest (Bitwarden's own `manifest.json` of both builds as fixtures, each wrong type,
  each limit), match patterns (the table of Chrome's documentation), the id from a key and from a path, the catalogue
  (placeholders, fallback to `default_locale`), path normalisation and traversal.
- Unit, `src/fetch`: `extension_may_load` for each rule; a page gets the same error for an absent and a refused file.
- Generated conformance cases for `ext.widl` and every method.
- Web test `web_extensions.odin` (no shell): a fixture with a background and a page. Checks: `sendMessage` with a
  callback, with a promise, with no receiver (`lastError`); a port in both directions and its disconnect; `storage.local`
  survives a restart of the world; `storage.session` does not; `storage.onChanged`; an alarm on the virtual clock; the
  background stops when idle and starts for a message; a method without its permission is absent.
- e2e `extensions.odin`: load the fixture, the button shows, a click opens the popup, the popup's text shows, Escape
  closes it and frees its page; reload and remove leave nothing allocated.
- Chrome-world test (`chrome_start`): the toolbar with 0, 1 and 40 extensions; the badge.
- **The test that breaks this design on day one:** the popup calls `storage.local.get` while the background is
  stopped and a second popup message is queued. Order and answers must hold with the background starting in between.

#### Status of phase 1

Written:

- `src/extensions`: `settings.odin`, `manifest.odin`, `match_pattern.odin`, `id.odin`, `package.odin`, `i18n.odin`,
  `storage.odin` (the areas), `registry.odin` (images, the list, grants compiled when they change), `json_text.odin`.
- `src/fetch/extension_scheme.odin`: the hop (files read on the blocking pool), `extension_may_load` rules 1 to 3, the
  CSP header of pages and the background, the CORS rule for granted hosts. `src/url`: the tuple origin and the secure
  context of `chrome-extension:` and `moz-extension:`.
- `api/ext.widl` (the transport). `src/page`: `ext_realm.odin` (both threads), `ext_router.odin`, `ext_background.odin`
  (a service worker host with `Sw_Registration.extension`), `ext_api.odin` (runtime, i18n, storage, tabs, windows, action,
  alarms, permissions, management, extension). `native/js/odin`: `ext_runtime.odin` and `ext_api.js`.
- `src/browser`: `ext_shell.odin`, `ext_toolbar.odin`, `ext_page.odin` (`about:extensions` with the install prompt).
- Tests: unit tests of `src/extensions` and `src/fetch/extension_scheme_test.odin`; the e2e test
  `src/tools/e2e/extensions.odin` with the fixture `examples/extensions/hello`; Bitwarden's manifests of both builds in
  `examples/extensions/manifests/`.

Different from the plan, and why:

- The API description was one table in `src/page/ext_api.odin` (methods and events, their permission, their contexts),
  replaced after phase 2 by the dialect (see "Status of the dialect").
  `chrome.*` is built from what `Ext_info` lists for the context, by `ext_api.js`. The bindgen dialect
  (`[Permission]`, `[Contexts]`, `event`) and `api/ext_<namespace>.widl` are not written: arguments are decoded by each
  implementation from JSON. This keeps one description; the generated decoders come with the dialect.
- The popup opened in a tab of its own in phase 1; it is a panel under its button since (`ext_popup.odin`, see phase 2).
- `extensions.worlds.*`, content scripts and `web_accessible_resources` frames came with phase 3 (rule 3 of
  `extension_may_load` was written in phase 1).

Not written yet: the web test `web_extensions.odin` (the e2e test covers its checks), the chrome-world test of the
toolbar, the generated conformance cases per API method, the overflow menu of the toolbar, icons from `ImageData`.
(`state.txt` came with phase 2.)

### Phase 2: log in and unlock

Scope: what the login and the vault need beyond phase 1. `idle` (the toolkit's last input time). `offscreen`
(`ext_offscreen.odin`). `tabs.create`, `update`, `remove`, and the tab events. `windows.create` (popout), `update`,
`remove` and the window events. `runtime.getContexts`, `reload`, `onInstalled`, `onStartup`, `openOptionsPage`.
The clipboard in extension pages with `clipboardRead` and `clipboardWrite` and no user action. `.zip` and `.crx`
install. Fixes for each web platform gap the login shows (expected in `crypto.subtle`, WebAssembly streaming, IndexedDB,
`import()`, CSS of the Angular popup).

The user can: log in to a Bitwarden account, see the vault, lock, unlock with the master password, copy a password,
restart Wren and unlock again, open the popout window.

Tests: web tests for `idle` on the virtual clock, `offscreen` (create, one at a time, close, message), tab and window
events in order. e2e: the fixture's popup writes the clipboard; a tab opened by `tabs.create` shows; an install from a
zip and from a crx; the session restores the extension. A test server route plays a small login API for a fixture that
does fetch, PBKDF2 and AES-GCM in its background, then stores the result.

#### Status of phase 2

Written:

- `src/extensions/archive.odin`: the `.zip` and CRX3 reader (central directory, stored and deflate entries, CRC-32,
  the CRX3 protobuf header for the public key) and the unpack into `<profile>/extensions/<id>/package/`. Every entry is
  checked before anything is written; each entry inflates into a buffer of its declared size. The id: the CRX3 key,
  else the manifest's `key`, else the archive's path; `image_load` takes it (`forced_id`) at each later start.
  `about:extensions` has "Install from file…" and takes a package path in its field.
- `state.txt` (`registry.odin`: `state_serialize`, `state_parse`, `Extension.listeners`): the events the background
  listens to, saved after its script ran and when they change. At the browser's start a background with known
  listeners does not run; an event starts it only when it listens to it. An install or a reload learns them again.
- `src/page/ext_offscreen.odin`: `offscreen.createDocument` (answers at the document's load event, fails after 30 s
  without one), `hasDocument`, `closeDocument`; one per extension; a `CLIPBOARD`-only document closes after
  `extensions.offscreen.max_lifetime_ms`. The context kind `Offscreen` has `runtime` only. The shell hosts the
  document in a tab of no window (`src/browser/ext_window_api.odin`).
- `src/page/ext_tabs.odin`: `tabs.create`, `update`, `remove`; `windows.create` (`type: "popup"`: the popout window,
  with no tab strip and no toolbar), `update` (focus, position), `remove`; `runtime.getContexts`, `reload`,
  `openOptionsPage`. A call is checked at once, then the shell acts in a task of the loop of its own. The events
  `tabs.onCreated`, `onUpdated` (`loading` at the request, `complete` at the document's load event), `onActivated`,
  `onRemoved`, `windows.onCreated`, `onRemoved`, `onFocusChanged`, built per extension (URL and title only when it may
  see them).
- `src/page/ext_idle.odin`: `idle.queryState`, `setDetectionInterval`, `onStateChanged`, from the time since the last
  input in Wren's windows (`ext_watch` reads each frame's events). One timer for every extension, set only while a
  context listens.
- The clipboard: a page of an extension with `clipboardWrite` or `clipboardRead` (popup, tab, offscreen document) uses
  `navigator.clipboard` with no focus and no gesture (`js_clipboard.odin`).
- The JSON of the router's messages and events: the format strings double their braces (`fmt` reads `{` as an argument).
- Tests: `src/extensions/archive_test.odin` (zips, hostile entries, limits, CRX3, the install, `state.txt`, idle); e2e
  `extensions_vault_packed_offscreen_tabs` and `extensions_vault_restart` with the fixture `examples/extensions/vault`.

Different from the plan, and why:

- **The popup is a panel under its button** (done after phase 2). `Frame_View` became `Page_View` (`page_view.odin`): a
  document, its tab, its layout at a size, its paint into a rectangle, its pointer and keyboard routed with the page area
  moved to it, the geometry its scripts read. Frames and the popup use it; a side panel would too. The window's own tab
  page keeps `page_prepare` and `page_paint` (`page_frame.odin`): its first paint hold, history restore, the page
  thread and the chrome frames are a window tab's alone. The toolkit's `ui.popover` holds the view (a `ui.custom` box);
  `ui.ctx_menu` was not used, as a menu takes every key of the window. The popup's input is taken before the page's
  (`ext_popup_events`), and the window's keyboard is lent to its document for each event, then given back. Not yet: a
  `<select>` list of the popup is drawn by the window's page paint, not in the panel; Wren's shortcuts (Ctrl+T)
  do not work while the popup is open.
- **The bindgen dialect came after phase 2** (see "Status of the dialect" below).
- **Idle is the browser's, not the system's.** The toolkit has no time since the last input of the whole system (Win32
  `GetLastInputInfo`, Wayland `ext-idle-notify`, X11 screen saver): it is a toolkit addition to make.
- A popout window is saved in the session as a normal window.
- No web tests on the virtual clock yet (idle, offscreen, event order): the e2e tests cover the same paths; the idle
  test sets the time of the last input instead of waiting.
- The login API route of the test server and its PBKDF2 / AES-GCM fixture are not written.

#### Status of the dialect

Written (between phases 2 and 3):

- `src/tools/bindgen/idl/ext.odin`, `ext_check.odin`: `namespace` declarations in `api/*.widl`, next to `module`. A
  namespace describes JSON shapes: `struct` (optional members), `enum` (strings), `typedef (A or B) Name` (a union of
  members of different JSON kinds), `const`, methods, `event`, `[Local] attribute`. Attributes: `[Permission=]`,
  `[Contexts=]` (Background, Popup, Tab, Page, Offscreen, Content), `[Manifest=action]`, `[Host=]` (methods with the
  same parameters share one implementation), `[Local]` (answered in the realm), `[Min=]` and `[Max=]`.
- `api/ext_runtime.widl`, `ext_i18n.widl`, `ext_storage.widl`, `ext_tabs.widl`, `ext_windows.widl`, `ext_action.widl`,
  `ext_alarms.widl`, `ext_permissions.widl`, `ext_management.widl`, `ext_extension.widl`, `ext_idle.widl`,
  `ext_offscreen.widl`: every namespace of phases 1 and 2. The hand table of `ext_api.odin` is gone.
- Generated: `src/page/ext_api_generated.odin` (the tables `EXT_METHODS`, `EXT_EVENTS`, `EXT_LOCALS`,
  `EXT_NAMESPACES`; a decoder per type and per method; the trampolines, so an implementation with a wrong prototype
  does not compile), `src/page/ext_api_generated_test.odin` (the conformance cases: arguments that decode, missing,
  of a wrong type, past a bound; the gate with and without the permission, the action, in each kind of context),
  `docs/api/ext/` (the reference).
- The arguments are matched to the signature in the host, as Chrome does (`ext_match`, `src/page/ext_decode.odin`):
  an optional parameter is left out when the argument in its place does not have its kind. `ext_api.js` no longer
  knows any namespace: it builds `chrome.*` (and `browser.*` with promises only, for the Firefox flavour) from what
  `Ext_info` lists, with the constants it gives.

Different from the plan, and why:

- The implementations keep the form `proc(x: ^Ext_Call, a: <Args>)` and answer through `ext_ok` / `ext_fail`: several
  answer later (tasks of the shell, `sendMessage`, `offscreen.createDocument`), so a returned result does not fit. The
  result types are in the description for the reference; no result encoder is generated.
- `chrome.*` is built by `ext_api.js` from `Ext_info` and the generated tables, not by a generated `ext_gen.odin`: the
  host already sends the lists per context, and one generated table serves the gate, the realm and the tests.
- Unions are named (`typedef`); a parameter cannot write one inline.

### Phase 3: autofill

Scope: `src/page/ext_worlds.odin` and the split of section 3.6 in `js_realm.odin`, `js_events_host.odin`,
`js_observers.odin`, `js_custom_elements.odin`, `js_dom_events.odin`, `timers`, `message.odin`.
`src/page/ext_inject.odin` (static scripts, CSS, `run_at`, `all_frames`, globs). `api/ext_scripting.widl`
(`executeScript` with `files` and `func`, both worlds; `insertCSS`, `removeCSS`; `registerContentScripts`,
`getRegisteredContentScripts`, `unregisterContentScripts`). `tabs.sendMessage`, `tabs.connect`. `api/ext_webnavigation.widl`.
`ext_dom.widl`. `web_accessible_resources` (rule 3) and sandbox pages. `tabs.captureVisibleTab`. Host grants in
`about:extensions`.

The user can: open a login page, see Bitwarden's inline menu on the field, choose a login, see the form filled; fill
from the popup.

Tests:

- Web test `web_worlds.odin`: a variable, a wrapper property and a prototype change of one world are invisible in the
  other; listeners of both worlds run in order; `stopImmediatePropagation` crosses worlds; `postMessage` reaches both;
  a `MutationObserver` of each world fires once; an inserted script runs in the main world; `customElements` is `null`;
  a closed shadow root is reachable only through `dom.openOrClosedShadowRoot`; closing the page with both worlds
  running leaves nothing allocated; a slow script in an isolated world is stopped and the page lives on.
- Web test `web_content_scripts.odin`: `run_at` order against the page's first script; `all_frames`; `exclude_matches`;
  no injection without a host grant, in `about:` pages and in another extension's page; CSS applies and is absent from
  `document.styleSheets`; `executeScript` returns the result per frame.
- e2e: a fixture fills a form of `examples/site` after a click in its popup; a web-accessible frame shows in the page;
  a page cannot load a file that is not web-accessible.
- Measure (`-Perf`): section 5, the cost of a second world per frame.

#### Status of phase 3

Written:

- `src/extensions/content_scripts.odin`: the index of content scripts by host (built once per image, and once per change
  of the registered scripts), the full test of an entry (`matches`, `exclude_matches`, `include_globs`,
  `exclude_globs`, `all_frames`, `match_about_blank`, `match_origin_as_fallback`), and the registered scripts in one
  arena. The image reads the files of the manifest's content scripts with the package (`Image.script_sources`): a
  `document_start` script has no time to wait for a file. The permissions `scripting` and `webNavigation`. The
  preferences `extensions.worlds.max_per_document`, `extensions.scripting.max_registered` and
  `extensions.content_scripts.idle_ms`.
- `src/page/ext_worlds.odin`: an isolated world is one more engine instance on the page (`Page.worlds`), started with
  `START_ISOLATED` (`customElements` is `null`). What is split by world: the checkpoint drains each world's jobs
  (`js_checkpoint`); a trap or a slow script stops the world and not the page (`world_trapped`, `js_call`); the
  bytecode cache and the pins answer a world's engine (`from_engine`); a `MutationObserver` queues its records in its
  world; a `MessagePort` delivers to the world that bound it (`Port_End.world`); a message posted to the window is
  fired once per world with its own copy of the data, and each of these events reaches the listeners of its realm only.
  The extension record of a world is found by the calling instance (`ext_of`), never by what the guest says.
- `src/page/ext_inject.odin`: the three points of a document (Start at the adoption of the parsed tree, End when the
  parser finished with `readyState` interactive, Idle at the load event or `extensions.content_scripts.idle_ms` after
  End), the scripts of the manifest and of `registerContentScripts` that match, their CSS as injected sheets of the
  author origin (the style engine keeps them when the document's sheets are cleared; no element owns them, so
  `document.styleSheets` does not list them). The `documentId` of each document.
- `api/ext_scripting.widl` (`executeScript` with `files` or `func` and `args`, both worlds, `frameIds`,
  `documentIds`, `allFrames`; `insertCSS`, `removeCSS`; `registerContentScripts`, `getRegisteredContentScripts`,
  `unregisterContentScripts`, `updateContentScripts`), `api/ext_webnavigation.widl` (`getFrame`, `getAllFrames`,
  `onCommitted`, `onDOMContentLoaded`, `onCompleted`), `tabs.sendMessage` and `tabs.connect` (`Ext_connectTab` in
  `api/ext.widl`). `src/page/ext_scripting.odin` (one record per call: its files read on the blocking pool, then run
  from a task of its own, then the answers of the worlds), `src/page/ext_webnavigation.odin`.
- The router: a content script's context knows its tab, its frame and its document; its `MessageSender` has `tab`,
  `frameId`, `documentId` and the document's origin. `tabs.sendMessage` and `tabs.connect` reach the worlds of the
  extension in that tab, in documents it still has a host grant for.
- Tests: `src/extensions/content_scripts_test.odin`, `src/page/ext_scripting_test.odin`; the e2e test
  `extensions_content_scripts_autofill` with the fixture `examples/extensions/autofill` and the pages
  `examples/site/extensions/`: a content script reads and fills a login form in its world; the page sees none of its
  globals; `document_start` runs before the page's first script; the frame of another origin gets the `all_frames`
  script only, a frame `exclude_matches` names gets none; the CSS applies and is not in `document.styleSheets`; window
  messages reach both worlds; `tabs.sendMessage`, `tabs.connect`, `executeScript` (isolated, a promise, every frame,
  MAIN), `insertCSS`, `registerContentScripts`, `webNavigation`; a web-accessible file loads in the page and another
  file of the extension does not.

Different from the plan, and why:

- **A world has the frames imports.** Without them `window.postMessage` and the named access of the global do not
  work, and content scripts use both. So `window.frames`, `parent` and `contentWindow` in a world give the other
  documents' page realms, not the same extension's world there. A content script must not hand its objects to them.
- **A window message is one event per realm**: the page's realm first, then each world in the order they were made,
  not interleaved by the order of registration. In a world its `source` is `null` and it carries no ports (they stay
  with the page's realm).
- **`executeScript` answers `null` for files and for the MAIN world**: a function's value comes back from an isolated
  world through a hook only that world's scripts see; the page's realm has no way back the page could not forge.
- **Scripts run at once.** `injectImmediately` is accepted; a document that exists gets the script now.
- **Registered scripts last until the browser exits or the extension reloads** (`persistAcrossSessions` is accepted,
  `state.txt` does not keep them yet).
- **An extension that stops** (disabled, reloaded, removed) stops its worlds in the documents already open; they do
  not start again there, and the CSS it added stays until the document goes.
- **`use_dynamic_url` stays phase 6**: the key is read, the URL host is the id.

Not written yet: `ext_dom.widl` (`dom.openOrClosedShadowRoot`), `tabs.captureVisibleTab`, sandbox pages, the switch
per host pattern in `about:extensions`, the other `webNavigation` events (`onBeforeNavigate`, `onErrorOccurred`,
`onCreatedNavigationTarget`, `onReferenceFragmentUpdated`, `onHistoryStateUpdated`, `onTabReplaced`: declared, never
sent), `slotchange` in a world (fired through the page's realm only), IndexedDB, `Worker`, `WebAssembly`, Web Audio,
`MediaSource` and `navigator.serviceWorker` in a world (their callbacks go to the page's realm), the web tests `web_worlds.odin` and
`web_content_scripts.odin` (the e2e test covers their main paths), the measure of a second world per frame.

### Phase 4: context menus and the save-login bar

Scope: `api/ext_contextmenus.widl`, `ext_context_menu.odin`, the hook in `context_menu.odin`, `activeTab`.
`api/ext_webrequest.widl` as an observer (`onBeforeRequest`, `onBeforeRedirect`, `onHeadersReceived`, `onCompleted`,
`onErrorOccurred`, read-only), in `src/page/ext_webrequest.odin` on `fetch.observer_add`. `api/ext_notifications.widl`.

The user can: right-click a field, choose "Bitwarden > Autofill login > (a login)"; copy a password or generate one
from the menu; submit a new login and get the bar that saves it.

Tests: chrome-world test of the menu (contexts, patterns, submenu, separators, 1000 items). Web test: `onClicked` data
for a link, an image, a selection, an editable field, a frame; `webRequest` events in order for a redirect chain, and
none for a host without a grant. e2e: the fixture's menu item changes the page.

### Phase 5: keyboard shortcuts

Scope: `api/ext_commands.widl`, `ext_commands.odin`, the entries in `commands.odin` and the palette, the editor of
keys in `about:extensions`, `action.openPopup`, key conflicts.

The user can: press Ctrl+Shift+L to fill the login, Ctrl+Shift+Y to open the popup, Ctrl+Shift+9 to generate a
password; change a key.

Tests: unit tests of key parsing (`Ctrl+Shift+Y`, `MacCtrl`, media keys, per-platform keys) and of conflicts.
Chrome-world test: the command is in the palette, the key fires it, a key of Wren wins over a suggested key. e2e: the
command reaches the background and grants `activeTab`.

### Phase 6: parity of the Chrome build

Scope: `webRequest.onAuthRequired` with `asyncBlocking`. Passkeys through Bitwarden (`world: "MAIN"` at
`document_start`, the page's `navigator.credentials`). `use_dynamic_url`. `permissions.request` and `remove`,
`onAdded`, `onRemoved`. `runtime.setUninstallURL`, `onUpdateAvailable`, `requestUpdateCheck` (answers `no_update`).
`storage.sync` limits. Incognito answers (`false` everywhere). Every Bitwarden screen and setting checked by hand with a
list kept in `docs/extensions-bitwarden.md`.

The user can: use every Bitwarden feature except biometric unlock, the side panel and the browser-autofill override.

Tests: web test of the auth provider against the test server's 401 route (credentials given, cancel, timeout then the
prompt). e2e of a passkey with the virtual authenticator replaced by a fixture extension.

### Phase 7: the Firefox flavour

Scope: the flavour in the registry, `moz-extension://<uuid>/`, the `browser` namespace, the background event page,
structured clone for messages, `browser.runtime.getBrowserInfo`, `browser.contentScripts` absent in MV3,
`blocking` `onAuthRequired` with a promise, `menus` as an alias of `contextMenus`, Firefox-only manifest keys ignored
with a warning. The user agent question of section 6.

The user can: load Bitwarden's Firefox MV3 build and repeat phases 1 to 5 with it.

Tests: the phase 1 to 5 fixtures built once more with `browser.*` and `background.scripts`; the same test files run
both flavours from one table.

### Later, not planned here

Store install and updates, native messaging, `declarativeNetRequest` on `fetch.Interceptor`, `sidePanel`, `cookies`,
`downloads`, `devtools`, Manifest V2.

## 5. Risks and how to measure them

| Risk | Why | Measure | Limit to act on |
|---|---|---|---|
| The Angular popup is slow to open | about 5 MB of script, parsed and run by the interpreter at each open; the popup page is new each time | `jspage` on `popup/index.html` served from the fixture server: time to first paint, time to the login form; the bytecode cache on and off | more than 1 s to the login form on the reference machine: keep the popup page warm for `extensions.popup.keep_warm_ms` after close, and check the bytecode cache covers extension files |
| Unlock is slow | PBKDF2 with 600000 rounds or Argon2id in the SDK's WebAssembly, in the background | a `-Perf` web test: `crypto.subtle.deriveBits` PBKDF2-SHA256 600000 rounds; the SDK's Argon2 in a worker | more than 3 s: PBKDF2 must run natively off the loop thread (check `bindings_crypto_subtle.odin`); Argon2 depends on Wasmtime speed, not on the interpreter |
| A second realm per frame costs time and memory | Bitwarden injects in every frame of every page | per world: start time and committed memory (`control_stats`), on a page with 0, 1 and 20 frames; the page load benchmark of `docs/performance.md` with and without Bitwarden | more than 5 % on the load benchmark or more than 8 MiB per world: create the isolated world only when the first script runs, share the pre-initialised image pages copy-on-write, delay `all_frames` injection for frames out of view |
| The background restarts too often | each start runs 3 MB of script | count starts and start time per hour of use, in `about:extensions` | more than one start per minute in normal use: raise `extensions.background.idle_ms`, keep a port open from the popup |
| Wrapper collection across worlds leaks nodes | the grouping by tree in `js_realm.odin` was written for one realm per document | the leak check of every web test of phase 3; `e2e` memory growth scenario with a content script that adds and removes 10000 nodes | any growth after collection fails the test |
| Web platform gaps in the popup and the content scripts | Bitwarden targets Chrome 134 | run the fixture `examples/extensions/probe`, which lists every web API of section 2.2 as present or absent; the console of the popup | each absent API is a task before the phase that needs it |
| API gaps | Bitwarden calls a method Wren does not have, during start | the router counts calls to unknown methods and logs each name once; `about:extensions` shows the list | the list must be empty for the flows of the current phase |
| An extension reads a page it has no grant for | many paths: scripts, messages, tab data, requests | the generated conformance cases; one web test per path of rule 4 in section 3.11, each with a grant withdrawn | any pass without a grant is a release blocker |
| A page detects or attacks an extension | DOM changes are visible; web-accessible frames can be framed and clicked | web tests: a page cannot read the frame, cannot find the id without `web_accessible_resources`, cannot receive a port | as above |
| A hostile package | zip bombs, path traversal, a huge manifest, 20000 content scripts | unit tests of the package reader and of each limit | as above |
| The dialect change in `bindgen` grows | JSON shapes with unions and optional callbacks | count the methods that need hand-written decoding | more than 10 % by hand: extend the dialect, do not add a second generator |

## 6. Open questions for the user

1. **Which build first.** The plan starts with the Chrome MV3 build: its background is a service worker, which Wren has,
   and Wren's user agent decides what Bitwarden detects. The Firefox build needs an event page and `browser.*` first.
   Confirm the order, or reverse phases 1 to 6 and 7.
2. **User agent.** Bitwarden's Firefox build looks for ` Firefox/` in `navigator.userAgent` in some paths, the Chrome
   build for ` Chrome/`. Is a per-extension user agent in extension contexts acceptable for the Firefox flavour? The
   other choice is that Firefox-flavour extensions see Wren's normal user agent and take their Chrome code paths.
3. **Unpacked id.** An unpacked Chrome-flavour extension without `key` gets an id from its path, as in Chrome. Moving
   the directory changes the id and loses its storage. Accept this, or store a generated key in `extensions.txt` at
   first load?
4. **Install prompt.** Chrome grants all `host_permissions` at install. Firefox MV3 treats them as optional and the user
   grants per site. The plan follows Chrome with a switch per pattern afterwards. Confirm, or choose Firefox's rule for
   both flavours (Bitwarden then needs a grant per site before autofill works).
5. **Extensions and the content blocker.** Do requests made by an extension's pages and background pass through the
   content blocker? The plan says no for extension contexts and yes for content scripts (they are the page's requests).
6. **Private windows and profiles.** Wren has one profile per App. Is "allowed in private windows" needed at all?
   The plan answers `false` to every incognito question.
7. **`gui_toolkit`.** The popup needs a toolkit popup panel that hosts a custom-drawn surface and follows its content
   size. If the toolkit lacks it, it is added there under a new tag, not in Wren. Answered: `ui.popover` holds a
   `ui.custom` box whose size Wren gives each frame; nothing was added to the toolkit.
8. **A store later.** If store install is wanted after phase 7, the CRX3 signature check and an update service must be
   planned. This changes nothing before phase 7 but decides whether `.crx` install keeps the public key now (the plan
   keeps it).
