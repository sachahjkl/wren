type: Fixed

**A page left behind no longer rewrites the next entry**: a page that keeps running behind its held frame called `history.replaceState` or `pushState` from a timer, and the address landed in the history entry of the page being loaded; it now gets a `SecurityError`, as a document that is not fully active does.
