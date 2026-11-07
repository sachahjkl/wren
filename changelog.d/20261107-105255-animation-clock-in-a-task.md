type: Fixed

**CSS animations and transitions keep their time**: the document's clock holds still during a task, as in browsers, so a script that reads getComputedStyle several times sees one instant however long its style passes take (css/css-text-decor interpolations failed on a loaded machine), and a paused animation that runs again starts where it stood, not as far on as the time the page drew nothing.
