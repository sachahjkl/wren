Type: Changed

**The artistic new tab shows its painting in about 40 ms instead of nearly a second** (`src/browser/newtab_art.odin`, `src/browser/newtab_art_page.odin`): the page names the cached file at a `file:` address instead of carrying it as a `data:` URL of up to 11 MB, and a painting is reduced when it arrives (`browser.newtab.art.short_side_px`, encoded as JPEG at `browser.newtab.art.jpeg_quality`, on a worker): 8 MB become 0.6 MB, and a new tab no longer holds the window for 800 ms.
The first new tab of a session shows at once what the last one left and nobody saw, without the network, and the folder is really kept under `browser.newtab.art.max_cache_mb`: the files of earlier sessions were never purged (400 MB for a cap of 128).
