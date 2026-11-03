type: Fixed

**A timer runs after the tasks queued before it**: a `setTimeout(0)` set from a task of the page (a script the parser runs while the page loads) ran before the tasks that script had queued, so a dialog's `toggle` event came after it; it runs after them now, as it did from a timer's script. WPT `toggle-events.html` passes whole.