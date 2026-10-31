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
- HTML filters (`html_filter.odin`): the `##^` filters of the visited host are applied to the body of its document (and
  frame) response, on the loader, before the parser reads it (`rewrite_filter`, a `fetch.Body_Filter`). The whole HTML body
  is held (up to `blocker.html_filters.max_body`, past which it streams through untouched), scanned with a tolerant byte
  parser (no DOM: tag delimiters, nesting of the same tag, the raw text of `<script>` / `<style>` / `<textarea>` /
  `<title>`), and every element a rule matches is deleted by byte range. The bytes are left in their original charset (only
  byte ranges are removed; nothing is re-encoded); `:has-text` decodes just the matched element's text to UTF-8 for the
  comparison. HTML answers of the targeted host only (never other types); the `#@#^` exceptions switch the host off; each
  removal is counted and logged (outcome "element removed (HTML filter)").
- Popups (`popup.odin`): the `$popup` filters stop the pop-up windows and tabs a page opens. The page's `window.open` path
  asks the blocker (`page.embedder.popup_check`) with the opener document and the target URL; a `$popup` match blocks the
  opening (no tab is created), exceptions (`@@||x^$popup`, `$~popup`) win. A pop-up backed by a recent click or key press
  (HTML transient activation) to the opener's own registrable domain is never stopped; one a script opens on its own is.
  Counted and logged (outcome "popup blocked").
- Pages (`page_hooks.odin`, `procedural.odin`, `scriptlets.js`): the cosmetic filters of the host become a user-origin
  stylesheet before the first style computation; generic `.class` / `#id` selectors are applied only when the DOM has that
  class or id (looked up again, debounced, when the DOM changes); procedural selectors are evaluated natively on the DOM
  and hide through the style engine (nothing is added to the page); scriptlets are carried out by the route that costs
  the page least (next section): on the DOM, on the response, or as hooks of the engine. Blocked frames and images are
  hidden.

## Syntax understood

Network: `||host^`, `|`, `*`, `^`, `/regex/`; `$third-party` (`3p`, `1p`, `first-party`), the types `script image stylesheet
xmlhttprequest subdocument media font websocket ping object other document popup webrtc csp_report`, `all`; `$domain=`
(`from=`), `$to=`, `$denyallow=`, `$method=`, `$important`, `$match-case`, `$badfilter`, `$redirect=`, `$redirect-rule=`,
`$rewrite=abp-resource:`, `$empty`, `$mp4`, `$removeparam=` (name or `/regex/`), `$csp=`, `$inline-script`, `$inline-font`,
`$header=`, `$replace=/search/replacement/flags` (the response text, any type), `$generichide`, `$elemhide`, `$specifichide`;
exceptions `@@`. A line with an option the engine does not know (`$cookie=`, `$ipaddress=`...) is not a filter: it is counted as
"not understood", as uBlock Origin does, and the dashboard shows the lines (My filters) and the count per list (Statistics).

Cosmetic: `##`, `#@#`, entities (`google.*`), `~domain` exclusions; procedural `:has() :has-text() :contains()
:-abp-contains() :-abp-has() :matches-css() :matches-attr() :matches-path() :min-text-length() :not() :upward()
:nth-ancestor() :remove() :style()`; AdGuard `#$#` style injections and `#%#//scriptlet()`; `##+js(name, args...)`.

HTML filters: `##^selector` (and the exceptions `#@#^`) remove elements from a document's markup before it is parsed, so an
inline ad script or a tracker iframe never exists (not hidden — gone). The selector is one element with
`script iframe div * ^script` (a tag name, `*`, or uBlock's leading `^`), `[attr] [attr=v] [attr*=v] [attr^=v] [attr$=v] [attr~=v]`,
`:has-text(x)` / `:contains(x)` (plain, `*` glob or `/regex/`), and `:not(:has-text(x))` / `:not([attr])`. Examples:
`example.com##^script:has-text(window.adConfig)`, `example.com##^iframe[src*="/ads/"]`.

## Scriptlets: where each one is carried out

The blocker does not run JavaScript in a page when it can do the thing natively. Each scriptlet (uBlock Origin's names, aliases and
`.js` suffixes; `scriptlet_route.odin`) has a route, from the cheapest for the page:

| route | scriptlets | how |
|---|---|---|
| **DOM** (Odin, no realm) | `remove-attr` (`ra`), `remove-class` (`rc`), `set-attr` (`sa`), `remove-node-text` (`rmnt`), `replace-node-text` (`rpnt`, `trusted-replace-node-text`), `click-element` (`trusted-click-element`), `href-sanitizer`, `disable-newtab-links`, `set-cookie` (`trusted-set-cookie`), `set-cookie-reload`, `remove-cookie`, `set-local-storage-item`, `set-session-storage-item` (`trusted-` forms), `remove-local-storage-item`, `remove-session-storage-item` | `dom_ops.odin`: operations on the document, fed by the mutation journal: the nodes inserted since the last pass are looked at once (never the whole document again, unless the journal lost entries), before the page styles, before every script that is about to run, and when the parser finishes. An inline script's text is rewritten before it runs (`before_script`). Cookies and storage are written through the page's own cookie jar and storage manager. Behavior as uBlock Origin's: `asap`, `stay`, a plain operation rests once the parse is done; text operations and clicks watch (clicks up to 10 s). Regular expressions are JavaScript's (`jsre.odin`: captures, lazy quantifiers, look-around, back-references, a step budget). |
| **network** (Odin, in the loader) | `json-prune-fetch-response` (`jpfr`), `json-prune-xhr-response` (`jpxhr`), `xml-prune`, `trusted-replace-fetch-response`, `trusted-replace-xhr-response` (`replace-in-response`), and the filter option `$replace=` | `rewrite.odin`: a `fetch.Body_Filter` on the response, by URL (and method), before the page reads it. JSON and XML answers are held until complete and rewritten once (JSON pruned by path with wildcards, XML by element selector, text by regular expression); nothing is held or parsed for a request no rule targets. `Content-Length` is dropped and the HTTP cache keeps the server's version. |
| **network, in the markup** | `set-constant` and `json-prune` of a variable the page's own HTML assigns (`var ytInitialPlayerResponse = {...}`) | the same `Body_Filter` on the document: the literal is found in the stream, pruned (or its property set) and written back before the parser reads it; the rest of the page flows through. A `set-constant ... undefined` on `ytInitialPlayerResponse.<key>` also prunes `<key>` from the answers of `/youtubei/v1/player` (the same object, asked for by the page for the next video), before any `$replace=` / `trusted-replace-*` filter of the list. |
| **engine hooks** (Odin in the JavaScript module, no interpreted code) | `set-constant` (`set`, `trusted-set-constant`), `abort-on-property-read` (`aopr`), `abort-on-property-write` (`aopw`), `abort-current-script` (`acs`, `acis`), `abort-on-stack-trace` (`aost`), `no-setTimeout-if` (`nostif`), `no-setInterval-if` (`nosiif`), `nano-setTimeout-booster`, `nano-setInterval-booster`, `no-fetch-if`, `no-xhr-if`, `addEventListener-defuser` (`aeld`), `window.open-defuser` (`nowoif`), `noeval`, `nowebrtc`, `json-prune` (`jp`, on `JSON.parse`) | `native/js/odin/qjs_blocker.odin`: before the first script the browser hands the rules to the engine (`wj_hook_install`), which installs C accessors and replaced functions; the decision (function text, current script, stack, arguments, URL) is made in C with the page's values, patterns are real JavaScript regular expressions. A call a rule does not concern costs the check and the call of the original. |
| **JavaScript** (last resort) | raw `#%#` JavaScript rules; every hook scriptlet when `blocker.hooks.native` is off | `scriptlets.js` run in the realm. Off by default for everything but the raw rules, which are the user's own code. |
| accepted, no effect | `json-edit` and `spoof-css` families, `addEventListener-logger` | uBlock Origin's logging and experimental ones: the line is understood and does nothing. |

Count of scriptlets that still run as JavaScript with the default settings: **none**, besides the lines the user wrote as raw JavaScript.

The arguments of `trusted-replace-*-response` follow uBlock Origin's: the third one is `url:<pattern> method:<verb>`, or a bare pattern
(text or `/regex/`, colons and spaces allowed) that is the URL's. `trusted-rpfr` / `trusted-rpxhr` are aliases. The `url:` form is also
read by `json-prune-*-response` and `xml-prune`.

### The first pages of a session

While the real filter index is not there (no valid cache in the profile: first start, a format change, lists changed on disk), only the small base
list is in force and the lists are compiled on a thread. A request let through meanwhile would escape every rule of the lists: the first page of
the session would carry its ad data (a YouTube watch page: `ytInitialPlayerResponse.adPlacements` intact). So the loader parks the requests to the
network (`fetch.hold_requests`) from the start until the compile job is done, for at most 20 s (`BOOT_HOLD_MS`), then starts them in order through the
real rules. With a valid cache the index is loaded in a few milliseconds at start and nothing is held. `about:`, `data:` and `file:` are never held.

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

`enabled`, `cosmetic.enabled`, `scriptlets.enabled`, `html_filters.enabled`, `html_filters.max_body`, `popup.enabled`,
`collapse.enabled`, `redirects.enabled`, `removeparam.enabled`,
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
- `tools\blocker_js.ps1`: how much JavaScript the interpreter runs for a page (`WREN_JS_PROFILE` samples summed over the tab's pages, and those of the blocker's own scripts), two executables side by side and the page without the blocker.
- `WREN_HOOKBENCH=1 build\blockertest.exe`: what a hooked API costs per call (ns), without the blocker, with the native hooks, with the JavaScript versions.
- Unit tests: `odin test src/adblock`, `odin test src/blocker`; end to end: `blockertest` (`tools\test_all.ps1`).

## Results

Engine (real lists: EasyList, EasyPrivacy, uBlock filters, AdGuard Base, Peter Lowe, URLhaus; 182,000 network and 73,000 cosmetic
filters): compile 290 ms, index 24 MB, cold load 13 ms, a request in about 4 us (p50 3 us, p99 21 us; 26 us before the gram
index and the regex prefilter).

Pages, in the real browser (`tools\blocker_perf.ps1`, cold HTTP cache, the same lists, one session per row; CPU is the process's
user and kernel time over the 15 to 30 s the page was given; "paint" is the first paint, "complete" readyState complete):

| site | blocker | requests (blocked) | MB | CPU s | memory MB | DOM nodes | paint ms | complete ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| allrecipes.com | off / on | 56 / 33 (3) | 6.57 / 3.08 | 63.3 / 27.0 | 485 / 364 | 5907 / 5880 | 2325 / 2010 | 2562 / 2477 |
| weather.com | off / on | 254 / 186 (21) | 13.37 / 5.92 | 78.8 / 64.1 | 813 / 641 | 2416 / 2084 | 763 / 1617 | 3695 / 2298 |
| dailymail.co.uk | off / on | 266 / 196 (7) | 27.4 / 18.5 | 106 / 73.5 | 1013 / 871 | 17047 / 13695 | 12189 / 2047 | n.a. |
| edition.cnn.com | off / on | 81 / 68 (3) | 15.8 / 13.8 | 58 / 46 | n.a. | 10171 / 10121 | 940 / 18200 | 20000 / 26000 |
| twitch.tv | off / on | 57 / 57 (1) | 3.6 / 3.6 | 43.5 / 29.6 | 365 / 363 | 281 / 281 | 450 / 780 | 2650 / 1540 |
| youtube.com | off / on | 119 / 119 (7) | 15.9 / 15.9 | 73.0 / 72.8 | 1106 / 1004 | 3442 / 3513 | 2183 / 2137 | 5193 / 4773 |
| old.reddit.com | off / on | 40 / 39 (4) | 3.2 / 3.2 | 36.3 / 33.5 | 753 / 799 | 817 / 861 | 772 / 802 | 4006 / 3535 |
| theguardian.com | off / on | 93 / 92 (12) | 2.78 / 2.78 | 21.9 / 22.0 | 428 / 455 | 5822 / 5825 | 920 / 937 | 1900 / 2130 |
| foxnews.com | off / on | 72 / 72 (0) | 9.6 / 9.8 | 33.4 / 33.5 | 396 / 415 | 12745 / 12745 | 760-1900 / 560-1830 | 2900 / 2960 |

Blocking changes the order in which a page's JavaScript runs. When a blocked script is what kept a heavy page script waiting,
that script starts earlier and can hold the main thread before the first frame (CNN with `cdn.optimizely.com`, Daily Mail's ad
loader): the first paint is then later although the bytes, requests and CPU time fell. An exception for `optimizely.com`
brought CNN's first paint back to 1.0 s. Where little is blocked (the Guardian's blocked requests are beacons, Fox News served
none from the lists) the numbers are the same within noise.
### Scriptlets without JavaScript

The interpreter's work for a page (`tools\blocker_js.ps1`: the samples `WREN_JS_PROFILE` takes of the page's functions, summed over every
page of the tab, 20 to 25 s after the navigation; a profile with the lists; `before` is the build that ran the scriptlets as
JavaScript, `after` this one). The samples of the blocker's own scripts (`wren-blocker:...`) are 0 in both builds on these sites.

| site | before | after | blocker off |
|---|---:|---:|---:|
| theguardian.com | 159 | 146 | 156 |
| allrecipes.com | 105 | 99 | 269 |
| weather.com | 556 | 542 | 1144 |
| dailymail.co.uk | 1125 | 1119 | 1119 |
| edition.cnn.com | 12 | 12 | 229 |
| youtube.com (watch), median of 4 | 1705 | 1733 | 1240 |

Reading: the scriptlets add nothing to the interpreter's work (before and after are the same within the noise of a sample taken
every few thousand interrupt checks), and where the blocker removes scripts the page's work falls (allrecipes, weather.com,
CNN). What the table cannot show is that the blocker no longer has a script in the realm at all: with the default settings no
JavaScript of the blocker is compiled or run (the page's `wren-blocker:scriptlets` script exists only for raw `#%#` rules, or with
`blocker.hooks.native` off). On YouTube the page itself does more work with the blocker on than off (about 40 %): it reacts to what
is blocked, which is not the blocker's own work.

What a hooked API costs per call (`WREN_HOOKBENCH=1`, median of 3 runs, ns per iteration of a loop that itself costs about 35):

| call | no blocker | native hooks | JavaScript versions |
|---|---:|---:|---:|
| `setTimeout` + `clearTimeout`, rule on the function's text | 1380 | 1925 | 3816 |
| `JSON.parse` of a small object, a `json-prune` rule | 3753 | 3195 | 8415 |
| read of a property a `set-constant` defines | 5677 (a miss on the window) | 118 | 177 |

A rule with a text pattern has to read the callback's source (about 0.5 us); a rule with an empty pattern does not.