type: Added

Service workers intercept the navigations of `<iframe>` and `<frame>` elements in their scope: `request.destination` is `iframe` / `frame` (also `Sec-Fetch-Dest`), `request.mode` is `navigate`; `Request.destination` is no longer always empty; a scope given to `register()` is resolved against the document (not the script) and keeps its query.
