type: Fixed

**A crash while a link loads** (imdb.com): the frame of the old page held through a navigation was painted after a script of that page had made its styles again (a `getComputedStyle`): the records of its display list were gone. It gives way to the page's canvas colour then, as for a changed document.
