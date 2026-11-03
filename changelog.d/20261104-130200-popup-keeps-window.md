type: Fixed

**A window opened by `window.open` keeps the Window of its first blank document**: `w = window.open(url); w.onload = ...` and `w.foo = 1` now apply to the page that loads in it when it is of the same origin, as in other browsers; the opener's script found no window to set them on (the blank document was closed when the navigation started). A page of another origin, or one whose Cross-Origin-Opener-Policy puts it in another browsing context group, still gets a window of its own.
