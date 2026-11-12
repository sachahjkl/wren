type: Changed

**Why `insertRule()` refused a rule is now listed with the sheet's errors.** The developer tools show the reason (an invalid selector, more than one rule) beside the sheet's own parse errors, and a sheet now counts the errors past the ones it keeps (`style.max_parse_errors_kept`).
