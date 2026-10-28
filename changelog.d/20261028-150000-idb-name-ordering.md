type: Fixed

**IndexedDB names** (`IDBObjectStore.name`, `IDBIndex.name`, `createObjectStore`, `createIndex`, `transaction`) : a store or index name that contains a U+0000 or a lone surrogate is kept intact, and a transaction's `objectStoreNames` is ordered by UTF-16 code unit, so a supplementary character such as U+1D11E sorts before U+FFFD. Renaming also re-raises a throwing `toString()` instead of failing. The names used to be routed through C strings (truncated at the first NUL) and ordered by their UTF-8 bytes.
