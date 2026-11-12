type: Added

**Offscreen documents and the clipboard for extensions**: `chrome.offscreen` makes, finds and closes an extension's hidden page, one at a time. A page made only for the clipboard closes after `extensions.offscreen.max_lifetime_ms`. The pages of an extension with `clipboardWrite` or `clipboardRead` use `navigator.clipboard` without a click, as in Chrome.
