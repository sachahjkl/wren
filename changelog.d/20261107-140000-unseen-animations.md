type: Changed

**Animations nobody can see no longer draw at every refresh** (`style.animations.unseen_tick_ms`): a CSS animation or transition of an element that is not rendered, or that only paints and lies far from the viewport, moves on four times a second and at its events instead of a frame per refresh; a page whose only motion is a hidden loader or a carousel far below the fold comes to rest. The bar along the top of a page not painted yet moves at the rate of the tabs' loading indicators (`browser.tabs.spinner_fps`), not at every refresh.
