type: Fixed

**Dialogs close as their `closedby` says**: a click outside an open dialog whose `closedby` is `any` closes it (light dismiss: a `cancel` it may cancel, then `close`; a click on the backdrop of a modal one counts as outside), and Escape asks the dialog on top to close whether `show()`, `showModal()` or its `open` attribute opened it (it was the top modal dialog only), unless its `closedby` is `none`.
