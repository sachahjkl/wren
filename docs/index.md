# Wren documentation

**Wren** is a web browser written from scratch in [Odin](https://odin-lang.org), for Windows, where
**WebAssembly is the only execution engine** — JavaScript included. The scripts of a page run in
[QuickJS-ng](https://github.com/quickjs-ng/quickjs) compiled to WebAssembly, inside the same
[Wasmtime](https://wasmtime.dev/) sandbox, memory cap and interruption as every other module. The web platform
itself (DOM, CSS, layout, painting, Fetch, the shell) is native Odin, drawn on Direct3D 11. There is no Chromium
underneath.

A page can also be a single `.wasm` file that calls the browser directly, through imports generated from
[Web IDL](https://github.com/w3c/webref): see [Web API](api/README.md).

## Installing

Wren is a single executable for Windows x64. There is no installer to run as administrator:

- Download the latest `.zip` from the [releases page](https://github.com/sachahjkl/wren/releases/latest) and
  unzip it anywhere, then run `wren.exe`.
- Or install it from [winget](winget.md): `winget install Froment.Wren`.

Every version is free during the beta. A [supporter licence](licence.md) unlocks nothing; it keeps the work going.

## Driving Wren

You rarely need to click to test a page. Wren ships one executable that is also its own client:

```powershell
wren ctl run --size 1280x800 --shot out.png https://example.com/   # one page, one capture
wren ctl start --size 1280x800                                     # a session you keep driving
wren ctl nav https://example.com/
wren ctl shot page.png
wren ctl stop
```

The same browser can be driven by **Puppeteer** and **Playwright** over the Chrome DevTools Protocol:

```
wren --remote-debugging-port=9222 --headless about:blank
```

Both paths are the same command engine. See [Remote control](remote.md) for `wren ctl`, and
[CDP and WebDriver BiDi](cdp.md) for the standard automation tools.

## Where to go

- **New here?** Read the [overview on the architecture page](architecture.md) for how a page owns its DOM, its
  WebAssembly instances, its requests and its timers, and how closing a tab tears all of it down in order.
- **Writing a page in WebAssembly?** The [Web API reference](api/README.md) lists every import, module by module,
  with its ABI.
- **Automating Wren?** [Remote control](remote.md) and [CDP](cdp.md).
- **Curious how far it has come?** [Web platform conformance](conformance.md) shows the WPT pass rate over time,
  with an honest caveat about the sample.
- **Looking for a feature?** The sidebar groups the features (the [content blocker](blocker.md),
  [media](media.md), [accessibility](accessibility.md), [several windows](windows.md), and more).

## Contributing to the docs

Every page in this site is a Markdown file under `docs/`. [How to write documentation](README.md) explains the
format and how the site is generated.
