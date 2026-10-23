# The content blocker

Wren blocks advertising, tracking and malware natively: the filter engine (`src/adblock`) is a portable Odin package, the
policy layer (`src/blocker`) joins it to the loader and the pages, and the interface is native (the shield at the end of the
address bar, its panel, and the dashboard `about:blocker`). Nothing is ever reported anywhere; the lists are downloaded
from their own servers, never shipped in the repository (the only list built in is a small one written for Wren).

The motivation is performance: a blocked request costs no DNS lookup, no connection, no script to download, parse and run,
and its frame or image leaves no empty box. Measurements are at the end.

## Architecture

```
 lists (text) --compile--> index (one binary blob) --load--> adblock.Engine --match--> Verdict
   downloaded in the background        cached in the profile        read-only, no allocation per request
   (conditional requests, checked)     (loaded in ~13 ms)
                                                    ^
 fetch.Loader --Interceptor--> blocker (counts, journal, dynamic rules, site switches) ----+
 page --embedder hooks--> element hiding before the first paint, procedural selectors, scriptlets
```

### `src/adblock`: the engine (independent, an API an extension API can sit on)

| call | what it does |
|---|---|
| `compile(lists, env, include)` / `Builder` | parses the lists (ABP, uBlock Origin and AdGuard syntax, hosts files, `!#if` / `!#include`) and builds the index blob |
| `engine_load(blob, own, verify)` | reads a blob in place (checked by a checksum), builds the bloom filters |
| `match(engine, &request)` | `Verdict`: `Allow`, `Block`, `Redirect` (with the stand-in's name) or `Exception`, and the filter that decided |
| `rewrite_url`, `csp_directives`, `match_response_headers` | `$removeparam`, `$csp`, `$header` |
| `page_flags(engine, url)` | `$document`, `$elemhide`, `$generichide`, `$specifichide` exceptions of a page |
| `cosmetic_for_host`, `cosmetic_keyed` | element hiding, scriptlets and HTML filters of a host, with exceptions applied; the generic selectors keyed to a class or id |
| `filter_ref`, `line_at`, `validate_list` | where a filter came from (list and offset) and the line to show, the validity of a downloaded list |

The index is one 8-byte aligned blob: string pool, 28-byte filter records, domain lists, and per class (block, allow,
redirect, removeparam, csp, header, page) a table by request host, a table by token, a table of 4-byte windows for filters
without a token, a table by source domain and a short always-checked list. Candidate lists carry the type and party bits of
each filter, so most candidates are discarded without reading their record. Regular expressions run on a Pike VM
(linear time, no catastrophic backtracking) behind an ordered list of required literals. Text of the rules is not stored:
a filter remembers (list, offset), and the journal reads the line from the `.src` file written with the index.

### `src/blocker`: the policy layer

- `fetch.Interceptor` (`src/fetch/intercept.odin`): called before DNS and connection, at the first hop and after each
  redirect, for documents, frames, scripts, styles, images, fonts, media, fetch / XHR, beacons, WebSocket handshakes and
  workers' requests; and with the response headers. It can block (error `net::ERR_BLOCKED_BY_CLIENT`, reported to the
  DevTools observer with `Observed.blocked_by` naming the rule), answer with a stand-in (`$redirect`), rewrite the URL
  (`$removeparam`), add a `Content-Security-Policy` (`$csp`) or block on a header (`$header`, large media).
- Dynamic rules (the matrix) are evaluated first and win over the lists; then the per-site switches (hard mode, remote
  fonts); then the engine.
- Per tab: counters, a time series of the blocks (the panel's graph), the hosts the page talked to by request type.
- Lists: `CATALOG` (uBlock filters family, EasyList, EasyPrivacy, AdGuard, Peter Lowe's list, URLhaus, regional and
  annoyance lists), custom lists by URL. A round downloads what is due (`blocker.update.interval_hours`), one list at a
  time, with `If-None-Match` / `If-Modified-Since`; a body that is not a filter list is refused and the previous copy stays;
  compilation runs on a thread named `wren-blocker-compile` at below-normal priority and the loop thread swaps the
  engine (documents keep the engine their cosmetic result came from until they end).
- Pages (`page_hooks.odin`, `procedural.odin`, `scriptlets.js`): the cosmetic filters of the host become a user-origin
  stylesheet before the first style computation; generic `.class` / `#id` selectors are applied only when the DOM has that
  class or id (looked up again, debounced, when the DOM changes); procedural selectors are evaluated natively on the DOM
  and hide through the style engine (nothing is added to the page); scriptlets run in the realm before any script of the
  page. Blocked frames and images are hidden.

## Syntax understood

Network: `||host^`, `|`, `*`, `^`, `/regex/`; `$third-party` (`3p`, `1p`, `first-party`), the types `script image stylesheet
xmlhttprequest subdocument media font websocket ping object other document popup webrtc csp_report`, `all`; `$domain=`
(`from=`), `$to=`, `$denyallow=`, `$method=`, `$important`, `$match-case`, `$badfilter`, `$redirect=`, `$redirect-rule=`,
`$rewrite=abp-resource:`, `$empty`, `$mp4`, `$removeparam=` (name or `/regex/`), `$csp=`, `$inline-script`, `$inline-font`,
`$header=`, `$generichide`, `$elemhide`, `$specifichide`; exceptions `@@`. Options that are not supported (`$replace=`,
`$cookie=`, `$ipaddress=`...) make the line count as not understood, like uBlock Origin does, and are shown in the
dashboard (My filters shows the lines; Statistics shows the count per list).

Cosmetic: `##`, `#@#`, entities (`google.*`), `~domain` exclusions; procedural `:has() :has-text() :contains()
:-abp-contains() :-abp-has() :matches-css() :matches-attr() :matches-path() :min-text-length() :not() :upward()
:nth-ancestor() :remove() :style()`; AdGuard `#$#` style injections and `#%#//scriptlet()`; `##+js(name, args...)`.

Scriptlets (`scriptlets.js`, uBO names and aliases): `set-constant`, `abort-on-property-read`, `abort-on-property-write`,
`abort-current-script`, `abort-on-stack-trace`, `no-setTimeout-if`, `no-setInterval-if`, `nano-setTimeout-booster`,
`nano-setInterval-booster`, `no-fetch-if`, `no-xhr-if`, `addEventListener-defuser`, `window.open-defuser`, `noeval`,
`nowebrtc`, `json-prune`, `json-prune-fetch-response`, `json-prune-xhr-response`, `remove-attr`, `remove-class`,
`set-attr`, `click-element` (`trusted-click-element`), `remove-node-text`, `replace-node-text`, `href-sanitizer`,
`disable-newtab-links`, `set-cookie`, `set-local-storage-item`, `set-session-storage-item`.

Stand-ins for `$redirect`: `noop.js`, `noop.css`, `noop.html` / `noopframe`, `noop.txt`, `empty`, `1x1.gif`, `2x2.png`,
`3x2.png`, `32x32.png` (generated), `noopmp3-0.1s`, `noopmp4-1s`, `google-analytics.com/ga.js`, `analytics.js`,
`inpage_linkid.js`, `googletagmanager.com/gtm.js`, `googletagservices.com/gpt.js`, `googlesyndication.com/adsbygoogle.js`,
`scorecardresearch.com/beacon.js`, `amazon_apstag.js`, `doubleclick.net/instream/ad_status.js`, `nobab.js`,
`chartbeat.js`, `outbrain-widget.js` (and uBO's aliases).

## Interface

- **The icon** at the end of the address row: green (filtering), amber (only the built-in list yet), grey (off, or off for
  this site, or not applicable), with a badge of the page's blocked requests; the tooltip says `N blocked on this page
  (M in all)`. It costs nothing at rest.
- **The panel**: power switch of the site (a click reloads), counters, graph of the blocks over the page's load, switches
  (element hiding, scriptlets, remote fonts, large media, hard mode), the matrix of the page's hosts by request type (a
  click on a cell blocks, allows, then resets that host and type for this site; Shift+click for every site), the element
  picker, the log, the dashboard, reload.
- **The element picker** (panel, context menu "Block element…"): aim, click, a precision slider walks the candidate
  selectors from the most to the least specific, the selector is editable, matches are outlined, Preview hides them for real,
  Create adds `site##selector` to My filters.
- **`about:blocker`**: Settings, Filter lists, My filters, My rules, Whitelist, Journal, Statistics, About. The whole
  configuration (lists, rules, sites, filters) exports and imports as one text file.
- Context menu of the page: Block element…, Block this resource. About:config: `blocker.*`.

## Preferences (`about:config`, `blocker.*`)

`enabled`, `cosmetic.enabled`, `scriptlets.enabled`, `collapse.enabled`, `redirects.enabled`, `removeparam.enabled`,
`update.enabled`, `update.interval_hours`, `update.start_delay_s`, `update.max_list_bytes`, `log.capacity`, `log.always`,
`large_media_kb`, `hard_mode`, `remote_fonts`, `cosmetic.debounce_ms`, `cosmetic.max_selectors`, `engine.cache`,
`badge.enabled`, `console.enabled`, `matrix.max_hosts`, `graph.points`.

## Measuring

- `build\adblockbench.exe <lists dir>` (`src/tools/adblockbench`): compile time, load time, memory, requests per second,
  latency distribution on real lists.
- `tools\blocker_perf.ps1`: loads each site with and without the blocker in the real browser (a fresh copy of a profile
  that has the lists, a cold HTTP cache) and collects `WREN_LOAD_REPORT` lines (first paint, readyState complete, requests,
  blocked, bytes, DOM nodes, CPU time, memory). `WREN_BLOCKER_TRACE=<file>` logs what the page hooks cost.
- `src/tools/blockerpages`: the same in the headless stack.
- Unit tests: `odin test src/adblock`, `odin test src/blocker`; end to end: `blockertest` (`tools\test_all.ps1`).

## Results

(see the table in the vault note and the section below once measured)
