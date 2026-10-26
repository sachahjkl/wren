type: Fixed

**Fullscreen on a page that lays itself out again** (YouTube's player): the window's `resize` event is fired (once per rendering update whose viewport size differs from the last one; it was never fired), the `fullscreenchange` events and the promise wait for the window to have its new size and the page to have been laid out for it (`Fullscreen_Embedder.deferred`, `fullscreen_settled`; they run in the rendering update, before that frame's `resize`).
