type: Changed

**Extension API arguments are checked as in Chrome**: a call with an argument of the wrong type, a missing property or a value out of range fails with an error that names the parameter and the property (`Error in invocation of tabs.create(object createProperties): Error at parameter 'createProperties': ...`), and optional leading arguments can be left out as in Chrome. The reference of every namespace is in `docs/api/ext`.
