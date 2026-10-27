type: Fixed

**`import()` from code without a script URL** (a string given to `eval`, `wren ctl eval`): an absolute specifier failed with "invalid base "<input>""; such code now resolves against the document's base URL, as HTML says.
