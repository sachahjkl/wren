type: Fixed

Fixed: `clientX` / `clientY` of mouse events in a scrolled page were in document coordinates (and `pageY` added the scroll twice); `e.buttons` was 0 during a drag; the boxes of `position: fixed` elements were offset by the scroll in the selection's auto-scroll, the context menu's keyboard position, the blocker's picker and the developer tools' highlight.
