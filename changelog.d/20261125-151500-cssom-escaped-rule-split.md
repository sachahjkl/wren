type: Fixed

**Stylesheets with escaped quotes in selectors no longer lose later rules after CSSOM access**: reading `sheet.cssRules` on stylesheets containing escaped quotes (such as Tailwind v4 arbitrary-value classes on x.com) previously dropped every subsequent rule on the next style rebuild, leaving modal overlays transparent and mispositioned.
