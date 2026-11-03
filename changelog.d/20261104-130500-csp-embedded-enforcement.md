type: Added

**CSP Embedded Enforcement**: `<iframe csp="...">` (and `iframe.csp`) requires a Content-Security-Policy of the documents the frame shows. Its requests say which (`Sec-Required-CSP`); a page that agrees (`Allow-CSP-From`) or has a policy as strict is shown with it enforced, about:blank, srcdoc, `data:` and `blob:` documents take it, any other is refused as `X-Frame-Options` refuses. The `sandbox` directive of a Content-Security-Policy header now sandboxes the document.
