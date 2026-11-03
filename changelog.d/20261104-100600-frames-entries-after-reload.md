type: Fixed

**Frames after back and forward**: going back (or forward, or reloading) to a page that was not in the back/forward cache shows each of its frames at the entry it had there (the page it had navigated to) instead of its `src`, and the steps of its frames stay in `history.length` and the back and forward buttons; from the back/forward cache, a position between a frame's steps moves the frame there.
