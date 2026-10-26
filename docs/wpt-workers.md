# WPT `/workers/`: what still fails, and why

`tools\wpt.ps1` runs the whole `/workers/` folder (its sub-folders included). Expectations: `wpt\expectations\workers.txt`
(written by `tools\wpt.ps1 -Update -Suites <a file listing workers>`). State on 2026-10-26 (tranche 5): 295 tests,
271 OK, 1021 of 1323 subtests pass (77.2 %).

The 23 tests that still end in TIMEOUT (some only under the load of 8 tests at once), by cause:

| Group | Tests | Cause | Can it be fixed here? |
|---|---|---|---|
| Other hosts and HTTPS | `SharedWorker_dataUrl`, `data-url-shared`, `modules/*-import-csp`, `modules/*-import-referrer`, `modules/shared-worker-options-credentials`, the cross-origin cases of `modules/shared-worker-import*` and `shared-worker-parse-error-failure` | They load from `https://{{domains[www1]}}:{{ports[https][0]}}` or `HTTPS_REMOTE_ORIGIN`. The local WPT server answers on `127.0.0.1` over HTTP only: these hosts do not resolve, and no HTTPS port answers. | No: it is the test server, not the browser. A full wptserve (DNS names, a certificate) would run them. |
| Windows a test opens | `SharedWorker-extendedLifetime*` (4) | They open windows (`window.open`), close them, and check that a shared worker outlives its last client. The runner drives one page with no window shown, and does not open popups. | Not in this runner. The `extendedLifetime` option itself is implemented (tranche 1). |
| A MessageChannel in a shared worker | `semantics/multiple-workers/008` | A shared worker creates a `MessageChannel` and passes a port to a dedicated worker it starts: the port's messages do not arrive. (Nested workers themselves work since tranche 5: `nested_worker*` pass.) | Yes: under investigation. |
| Frames that navigate | `semantics/navigation/001`, `002`, `semantics/reporting-errors/004`, `opaque-origin` | An iframe navigates and goes back (`history.back()` inside a frame), or runs sandboxed with an opaque origin. Frame session history and sandboxed origins are incomplete. | Partly. The work belongs to the frames and history code, not to workers. |
| Storage partitioning | `shared-worker-partitioned.tentative` | A shared worker seen from a third-party frame must be another one. Shared workers are keyed by the partitioned storage key since tranche 5 (`storage.partitioned`), but the test's third-party frame is on another host (`get-host-info` `REMOTE_ORIGIN`), which the local WPT server does not serve. | It belongs to the "other hosts" group; `tools\partition_e2e.ps1` checks the partitioning. |
| Timing | `Worker-postMessage-happens-in-parallel.https`, sometimes `Worker-creation-happens-in-parallel.https` and `SharedWorkerGlobalScope/name/*` | They measure that a worker runs while the page is blocked, or just take long under load (8 tests at once). Their expectations accept both results (`OK\|TIMEOUT`). | They pass on their own. |
| Remaining bugs | `WorkerGlobalScope-close` ("errors are delivered after close"), `semantics/encodings/004.worker`, `SharedWorker_blobUrl` (its cross-origin frame) | Under investigation. | Yes. |

Fixed during tranche 5:

- Nested workers (`new Worker()` in dedicated and shared workers): `nested_worker*`, the nested case of
  `dedicated-worker-in-data-url-context`.
- `modules/shared-worker-import.window` and `modules/shared-worker-options-credentials` pass on their own (only their
  cross-origin cases fail); under load they still time out at times (`OK|TIMEOUT`).

Fixed during tranche 4:

- Synchronous `XMLHttpRequest` in workers. It fixes the `worker-performance` subtest and `semantics/xhr/*`.
- A worker's uncaught error that its `Worker` object did not cancel now reaches `window.onerror`.
- `requestAnimationFrame` works in dedicated workers.
- A worker's script and `importScripts()` require a JavaScript MIME type over HTTP(S).
- A module shared worker whose graph fails fires `error` at its `SharedWorker`. Before, the test hung.
- `/html/webappapis/structured-clone/` is fetched, which brings the structured-clone battery.
- These test server handlers are now ported to Go: `common/redirect.py`, the `baseurl` redirects, `helper-redirect.py`, and the `modules/resources/*.py` scripts.
- `.headers` files now replace the server's `Content-Type`.
