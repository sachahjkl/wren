# Driving Wren with CDP and WebDriver BiDi

Wren can be driven by the standard automation tools — **Puppeteer**, **Playwright** (`connectOverCDP` or the BiDi
transport), **Chrome DevTools**, and WebDriver **BiDi** clients — over a local WebSocket. An adapter translates their
messages onto the same command engine `wren ctl` uses (`docs/remote.md`): there is one control path, not two.

## Turning it on

The adapter is **off by default**. Turn it on for one run with a command-line flag, or always with a preference:

```
wren --remote-debugging-port=9222 --headless about:blank
wren --remote-debugging-port=9222 https://example.com/
```

- `--remote-debugging-port=N` listens on port `N`. `--remote-debugging-port` with no number (or port `0`) lets the
  system pick a free one; it is written to `DevToolsActivePort` in the profile, as Chrome does (a tool reads it there).
- `--remote-debugging-address=ADDR` is accepted but **only loopback is honoured**: the server always binds `127.0.0.1`.
  A remote bind is a security hazard this build does not offer; a non-loopback address is a warning, not an error.
- The preference `remote.cdp.enabled` turns it on at every start (port `remote.cdp.port`, 0 = the system picks one).
- `remote.cdp.max_clients` (8) is how many tools may connect at once.

`--headless` and `--remote-debugging-port` go together naturally (a driven Wren needs no window), but either works alone.

## Connecting in one line

```js
// Puppeteer
const browser = await puppeteer.connect({ browserURL: "http://127.0.0.1:9222" });

// Playwright (CDP)
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
```

Both read `http://127.0.0.1:9222/json/version` to find the WebSocket endpoint, then speak CDP over it.

## The HTTP endpoints

| Path | Answers |
|---|---|
| `GET /json/version` | the product, the protocol version, and `webSocketDebuggerUrl` (the browser endpoint) |
| `GET /json` or `/json/list` | one entry per tab (`id`, `type` "page", `title`, `url`, `webSocketDebuggerUrl`) |
| `GET /json/new?<url>` | opens a tab, answers its entry |
| `GET /json/close/<id>` | closes the tab |
| `GET /json/activate/<id>` | brings the tab to the front |
| `GET /json/protocol` | an empty descriptor (tools fall back to their own copy of the protocol) |

A tool connects a WebSocket to `/devtools/page/<id>` (a page) or `/devtools/browser` (the browser). The adapter serves
one channel for the whole browser; the target a message is about is carried in its params (a `targetId`), and the
path's id is informational.

## The CDP methods covered

A useful subset — enough for navigation, script, DOM reads, input, screenshots and the common events. A method outside
it answers an "not supported by this adapter" error (`-32601`), so a tool can feature-detect.

- **Browser**: `Browser.getVersion`, `Browser.close`.
- **Target**: `getTargets`, `getTargetInfo`, `createTarget`, `activateTarget`, `closeTarget`, `attachToTarget`,
  `setDiscoverTargets`, `setAutoAttach` (a flat session; a CDP `sessionId` is the target's id).
- **Page**: `enable`, `navigate`, `reload`, `stopLoading`, `captureScreenshot`, `setLifecycleEventsEnabled`; events
  `frameNavigated`, `loadEventFired`, `lifecycleEvent`.
- **Runtime**: `enable`, `evaluate`, `callFunctionOn` (a thin shim: the function is called on the global object);
  events `consoleAPICalled`.
- **DOM**: `getDocument`, `getOuterHTML`, `querySelectorAll`, `getBoxModel` (the document's own selector engine, no
  script engine needed).
- **CSS**: `getComputedStyleForNode` (needs the page's JavaScript).
- **Input**: `dispatchMouseEvent`, `dispatchKeyEvent`, `insertText` (through the same synthetic-event path as a real
  device's, `platform.inject_event`).
- **Emulation**: `setDeviceMetricsOverride` (width, height, `deviceScaleFactor` → the window's size and DPI),
  `setUserAgentOverride`, `setTouchEmulationEnabled`.
- **Security**: `setIgnoreCertificateErrors`.
- `Network.enable`, `Log.enable`, `Performance.enable`, `Inspector.enable` are accepted (no-ops) so a tool's start-up
  does not stall.

Wren's own method names already follow CDP where it has the same thing (`docs/remote.md`), so most of the translation
is the envelope (sessions, string target ids) and the few results whose shape differs (a screenshot's `data`, a
target's string id).

## WebDriver BiDi

The same WebSocket also speaks a subset of WebDriver BiDi (a message whose method is a BiDi module — `session.`,
`browsingContext.`, `script.`, `input.`, `network.`, `log.` — is treated as BiDi):

- `session.new`, `session.status`, `session.subscribe`/`unsubscribe`/`end`.
- `browsingContext.getTree`, `navigate`, `reload`, `captureScreenshot`, `create`, `close`; event `browsingContext.load`.
- `script.evaluate`, `script.callFunction`.
- `input.performActions` / `releaseActions` are acknowledged (a tool may also drive input over CDP `Input.*`).
- `log.entryAdded` for console output.

A BiDi context id is a tab id as a decimal string, as a CDP `targetId` is.

## Security

- The server binds **`127.0.0.1` only**: a remote machine cannot reach it.
- The WebSocket handshake is refused when its `Host` or `Origin` header is present and not a loopback name
  (`127.0.0.1`, `localhost`, `::1`): the guard a page on a site would have to pass to reach the channel (**DNS
  rebinding**). A tool connecting by `ws://127.0.0.1:N` passes; a page on `https://evil.example` does not.
- It is **off unless asked for** (`remote.cdp.enabled` or `--remote-debugging-port`): a Wren that was not asked has no
  socket, no thread.
- Everything a client does is what the user could do in the window; there is no way into the file system but the paths
  a client gives to a capture (written with the user's rights). A capture is returned as base64 in the CDP reply.

## Limits (at the first cut)

- `Page.getFrameTree` answers an empty object; a tool that needs the real frame tree over CDP will not get it yet
  (BiDi `browsingContext.getTree` gives one context per top-level tab).
- `Network.getResponseBody`, `Network.setExtraHTTPHeaders` and the `Fetch.*` interception domain are not wired yet
  (`wren ctl network` reads the request log; the body store is not exposed over CDP).
- `printToPDF` is not offered.
- Remote objects from `Runtime.evaluate` are primitives (string, number, boolean, null, undefined); an object is not
  returned as a handle to walk with `getProperties`.
- One flat session is used (no per-target `sessionId` routing); a tool that opens several pages drives each by its
  `targetId` in the params.
