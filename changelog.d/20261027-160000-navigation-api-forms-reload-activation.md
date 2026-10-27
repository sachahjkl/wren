type: Added

**Navigation API: form submissions, the reload button, `activation`** (`page.navigation_form`, `page.navigation_user_reload`, `Navigation_activation`): a form submission fires `navigate` with its `sourceElement` (the submitter, else the form) and, for a POST, its `formData` (a submission planned before the document completely loaded replaces the entry); the browser's reload button (F5, Ctrl+F5) fires a user-initiated `navigate` the page may cancel or intercept; `navigation.activation` gives the navigation type, the current entry and the entry it came from.
