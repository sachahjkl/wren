type: Fixed

**`wren ctl wait --js` no longer hangs when the page is replaced during the wait.** If another document takes the tab, for example an about: page that reloads itself, the condition is now checked on the new document too.
