type: Changed

**A closure or an `arguments` object costs about half of what it did**: their shapes are made once a realm, and a sloppy function's `arguments` no longer makes a dictionary of its own at each call.
