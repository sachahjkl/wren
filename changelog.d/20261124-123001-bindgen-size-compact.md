type: Changed

**Smaller browser binary and embedded JavaScript engine image**: host API trampolines now share validation and return helpers with compact import tables, and generated JavaScript bindings use table-driven dispatch and read-only metadata tables instead of per-property wrapper functions.
