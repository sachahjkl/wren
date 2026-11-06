type: Fixed

**Stop before the server answers goes back to the page**: Escape during a navigation that had no answer yet left a tab with the old frame on screen and no page behind it, no input, the address of the page that never came and its entry in the history; the page comes back, alive, at its address and on its entry, a stopped back or forward included. A navigation that turns out to be a download gives the page back the same way, with its scroll position, its error chip and its `no-store` kept.
