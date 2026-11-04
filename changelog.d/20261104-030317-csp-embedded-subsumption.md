type: Changed

**CSP Embedded Enforcement compares source lists**: a frame's document whose own policy is at least as strict as the one `<iframe csp>` requires (its hosts within the required wildcards, paths and ports, no keyword or nonce more) is shown without `Allow-CSP-From`, and a `csp` attribute less strict than the parent's own requirement gives way to it.
