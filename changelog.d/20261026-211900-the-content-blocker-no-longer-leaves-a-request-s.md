type: Fixed

**The content blocker no longer leaves a request's context allocated when the browser closes during the download of its lists** (`updater_stop` cancelled the request, which sends no more events, and what they carried stayed: found by the check build of the CI, whose machine downloads the lists; reproduced here with `blocker.update.start_delay_s=0`).
