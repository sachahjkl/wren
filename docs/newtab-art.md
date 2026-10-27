# Artistic new tab

When `browser.newtab.art.enabled` is on, a new tab shows a random public-domain painting filling the window, with the
start page's shortcuts and the address bar legible over it, a discreet caption (title, artist, date, museum, a link to
the record) and two small buttons (**Another painting**, **Open the record**). It follows Google Arts & Culture's "art
new tab" idea, but every piece runs natively in Wren: the engine renders the page, the shell downloads and caches the
images. The option is **off by default**.

## When the network is touched

Never at start-up, never while the option is off, and never while the loader is held offline. The first time an art new
tab is actually shown in a session, a background task starts; from then on it keeps a sliding window of about
`browser.newtab.art.window` paintings ready, downloading a fresh one whenever a shown painting is consumed. The task
stops after `browser.newtab.art.idle_minutes` with no art new tab shown and resumes at the next one.

The only requests made are the source's listing API and the image files themselves. Nothing about the user is sent: no
identifier, no third-party referrer, an honest `User-Agent` (`Wren/<version>`). The images and their metadata live only
in the profile's temporary folder (`<profile>/tmp/newtab-art`), one JSON file of metadata beside each image, and are
removed with **Clear browsing data** (the "cached responses" kind, for all sites).

## Sources

`browser.newtab.art.sources` is a comma list tried in turn (replaceable):

- **`cleveland`** — [Cleveland Museum of Art Open Access](https://openaccess-api.clevelandart.org/). CC0 paintings, no
  key. A random slice of the ~3,900 CC0 paintings is listed; the larger `images.print` rendition is used, falling back
  to `images.web` (~900 px).
- **`commons`** — [Wikimedia Commons](https://commons.wikimedia.org/w/api.php). The *Google Art Project works by artist*
  and *Featured pictures of paintings* categories, listed with `generator=categorymembers` and `prop=imageinfo`
  (`iiurlwidth` for a bounded width, `extmetadata` for artist, title and licence). **Only freely licensed files are
  kept** (public domain, CC0, CC-BY / CC-BY-SA); non-commercial, no-derivatives and fair-use files are refused. The
  attribution is shown in the caption.

Google Arts & Culture itself has no public API and is not used. The Met (search returns 410) and the Art Institute of
Chicago (Cloudflare challenge) do not answer a client without a browser reliably and are not used either.

## Courtesy and validation

The downloader makes one request at a time per host and backs off exponentially on `429` / `403` / network error
(`browser.newtab.art.backoff_base_ms` doubling up to `browser.newtab.art.backoff_max_ms`). Every answer is validated
before it is kept: an `image/*` MIME type, a size below `browser.newtab.art.max_image_bytes`, a known image signature, a
probe decode with Wren's own image decoder, a sane aspect ratio (between 1:3 and 3:1) and a minimum width
(`browser.newtab.art.min_width_px`, 1280 px by default) for full-screen use. Files beyond `browser.newtab.art.max_cache_mb`
are purged oldest first.

## "Smart"

The painting chosen for a new tab suits the window's orientation (landscape for a wide window, portrait for a tall one);
a painting of the other orientation is shown whole over a blurred fill of itself rather than cropped to a sliver. The
last `browser.newtab.art.window` picks are remembered so the same painting does not repeat at once, and the next one is
pre-fetched while the current is on screen. Nothing downloads on a limited or offline connection.

## Preferences

| Preference | Default | What it does |
|---|---|---|
| `browser.newtab.art.enabled` | `false` | Turn the artistic new tab on. |
| `browser.newtab.art.sources` | `cleveland,commons` | Where paintings come from, a comma list. |
| `browser.newtab.art.window` | `20` | How many paintings are kept ready (the sliding window). |
| `browser.newtab.art.max_cache_mb` | `128` | Most disk the cached paintings take. |
| `browser.newtab.art.refresh_hours` | `12` | A kept painting older than this is refreshed. 0 = never. |
| `browser.newtab.art.show_caption` | `true` | Show the caption at the bottom. |
| `browser.newtab.art.offline_fallback` | `true` | An elegant gradient with the caption when nothing is ready yet. |
| `browser.newtab.art.min_width_px` | `1280` | Smallest width a painting may have. |
| `browser.newtab.art.max_image_bytes` | `8 MB` | Largest image file downloaded. |
| `browser.newtab.art.idle_minutes` | `30` | Stop the task after this long with no art new tab. 0 = never. |
| `browser.newtab.art.backoff_base_ms` | `2000` | First retry wait after a failure (doubles). |
| `browser.newtab.art.backoff_max_ms` | `300000` | Longest retry wait. |

## Trying it

1. Open `about:config`, set `browser.newtab.art.enabled` to `true`.
2. Open a new tab (Ctrl+T). The first one may be the plain start page or the fallback gradient while the first paintings
   download; open a few more tabs and they fill with paintings.
3. **Another painting** (or opening `about:home?art=next`) shows the next one; **Open the record** opens the museum's
   page for the painting.
4. **Clear browsing data** (about:sites, "cached responses" for all sites) empties the cache; the task refills it.
