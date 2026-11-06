type: Fixed

**A web font on its way no longer holds the whole page back.** The page paints at once and only the text waiting for its font stays invisible, as in other browsers: bbc.com's first paint goes from about 1.1 s to about 0.35 s. `first-contentful-paint` now comes when something is really shown.
