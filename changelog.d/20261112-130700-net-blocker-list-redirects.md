type: Fixed

**A filter list that moved is downloaded again**: the list updater follows up to `blocker.update.max_redirects` (5) redirects, to https addresses only. Before, a redirect left the list out of date with the error "the server answered 301".
