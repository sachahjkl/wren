type: Fixed

**Classic look: the light line along the top of a tab no longer vanishes and comes back in a cut** (`chrome_style.odin`, `title_fade_draw`): the fade at the end of a long title laid the tab's gradient over the whole height of the tab, the one-pixel light hairline included, so the line was hidden under the fade and showed again, sharply, where the fade ends. The fade now starts under the hairline.
