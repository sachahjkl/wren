type: Fixed

**Opening a dialog focuses what the HTML standard says**: a descendant with `autofocus` that can have the focus (one hidden, disabled or in a closed nested dialog is passed over), else the first one Tab reaches (a shadow host that delegates focus for what it delegates to, nothing inside another shadow tree), else the dialog itself; nothing for a dialog out of the document or inert. On close the focus goes back where it was before when it is still in the dialog, and from a modal dialog always; a focus left in a closed dialog goes to the body.
