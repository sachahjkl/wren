type: Fixed

**A click a script dispatches activates as a user's does**: `dispatchEvent(new MouseEvent("click"))` on a label clicks its control, on a check box or a radio button checks it (with `input` and `change`), on a link follows it; one that does not bubble activates its target only, and a submit button its listener disabled does not submit.
