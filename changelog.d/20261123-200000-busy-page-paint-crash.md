type: Fixed

**No crash while a page runs a long script**: when the window was scrolled or showed an animation while a page's script held the browser, and that script had read the page's styles (`getComputedStyle`) during a running animation, the browser could crash.
