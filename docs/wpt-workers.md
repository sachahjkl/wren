# WPT `/workers/`: what still fails, and why

`tools\wpt.ps1` runs the whole `/workers/` folder (its sub-folders included). Expectations: `wpt\expectations\workers.txt`
(written by `tools\wpt.ps1 -Update -Suites <a file listing workers>`). State on 2026-10-27: 295 tests, 270 OK,
992 of 1323 subtests pass (75.0 %).

The 25 tests that still end in TIMEOUT, by cause:

| Group | Tests | Cause | Can it be fixed here? |
|---|---|---|---|
| Other hosts and HTTPS | `SharedWorker_dataUrl`, `data-url-shared`, `modules/*-import-csp`, `modules/*-import-referrer`, `modules/shared-worker-options-credentials`, the cross-origin cases of `modules/shared-worker-import*` and `shared-worker-parse-error-failure` | They load from `https://{{domains[www1]}}:{{ports[https][0]}}` or `HTTPS_REMOTE_ORIGIN`. The local WPT server answers on `127.0.0.1` over HTTP only: these hosts do not resolve, and no HTTPS port answers. | No: it is the test server, not the browser. A full wptserve (DNS names, a certificate) would run them. |
| Windows a test opens | `SharedWorker-extendedLifetime*` (4) | They open windows (`window.open`), close them, and check that a shared worker outlives its last client. The runner drives one page with no window shown, and does not open popups. | Not in this runner. The `extendedLifetime` option itself is implemented (tranche 1). |
| Nested workers | `nested_worker_close_self.worker`, `semantics/multiple-workers/008` | A dedicated worker that creates another `Worker` gets `NotSupportedError`. | Yes, but it is a project of its own: the nested worker's messages, requests and lifetime must go through its parent worker's thread. Left for later. |
| Frames that navigate | `semantics/navigation/001`, `002`, `semantics/reporting-errors/004`, `opaque-origin` | An iframe navigates and goes back (`history.back()` inside a frame), or runs sandboxed with an opaque origin. Frame session history and sandboxed origins are incomplete. | Partly. The work belongs to the frames and history code, not to workers. |
| Storage partitioning | `shared-worker-partitioned.tentative` | A shared worker seen from a third-party frame must be another one (a partitioned storage key). | Yes, with the `storage.partitioned` work (tranche 4, item 5). |
| Timing | `Worker-postMessage-happens-in-parallel.https`, sometimes `Worker-creation-happens-in-parallel.https` and `SharedWorkerGlobalScope/name/*` | They measure that a worker runs while the page is blocked, or just take long under load (8 tests at once). Their expectations accept both results (`OK\|TIMEOUT`). | They pass on their own. |
| Remaining bugs | `WorkerGlobalScope-close` ("errors are delivered after close"), `semantics/encodings/004.worker`, `SharedWorker_blobUrl` (its cross-origin frame) | Under investigation. | Yes. |

Fixed during tranche 4:

- Synchronous `XMLHttpRequest` in workers. It fixes the `worker-performance` subtest and `semantics/xhr/*`.
- A worker's uncaught error that its `Worker` object did not cancel now reaches `window.onerror`.
- `requestAnimationFrame` works in dedicated workers.
- A worker's script and `importScripts()` require a JavaScript MIME type over HTTP(S).
- A module shared worker whose graph fails fires `error` at its `SharedWorker`. Before, the test hung.
- `/html/webappapis/structured-clone/` is fetched, which brings the structured-clone battery.
- These test server handlers are now ported to Go: `common/redirect.py`, the `baseurl` redirects, `helper-redirect.py`, and the `modules/resources/*.py` scripts.
- `.headers` files now replace the server's `Content-Type`.
