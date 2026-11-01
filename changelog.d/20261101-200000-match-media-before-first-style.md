type: Fixed

**`matchMedia` while a page loads** answers for the window's real scale and size. A list made by a script before the page's first style computation was answered for a scale of 1 and a default viewport, so at 175 % `matchMedia('(min-resolution: 1.4dppx)').matches` was false until that computation, which then fired a `change` event for a threshold nothing had crossed.
