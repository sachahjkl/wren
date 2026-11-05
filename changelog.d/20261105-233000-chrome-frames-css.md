type: Changed

**CSS off the page's thread**: while a script keeps the thread busy, the interface frames go on with more of the page.
  - Scroll-driven animations follow the wheel, the scroll bar and the keys at the offset on the screen, whatever they animate.
  - Animations and transitions of colours, shadows, radii, filters and clip-paths go on, with what inherits them, as those of transform and opacity did.
  - Animations and transitions of layout properties (`width`, `height`, `font-size`...) go on too when a whole layout of the page is cheap (`browser.shell.shown_layout_max_ms`): it is made on a copy, in each interface frame, and scripts read nothing of it.
  - A box with a running animation behaves from its start as `will-change` says, so nothing waits for the page at the first frame.
