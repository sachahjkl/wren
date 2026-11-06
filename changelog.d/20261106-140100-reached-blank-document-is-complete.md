type: Fixed

**A blank frame or window a script reached no longer counts as loading**: its document said `complete` while the back/forward cache and the tab's restore still waited for a load event that would never come.
