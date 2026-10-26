type: Fixed

**Ad data of `/youtubei/v1/player` is removed from its answers**: a `set-constant ytInitialPlayerResponse.<key> undefined` rule also prunes `<key>` from the answers of `/youtubei/v1/player` (the page asks for the next video that way), before the list's `$replace=` / `trusted-replace-*` filters, so `playerAds` and the ad entries no longer stay behind a renamed `adPlacements` (`"no_ads"`).
