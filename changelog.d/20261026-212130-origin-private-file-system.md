type: Added

**Origin private file system**: `navigator.storage.getDirectory()`, `FileSystemDirectoryHandle` (`getFileHandle`, `getDirectoryHandle`, `removeEntry`, `resolve`, `entries` / `keys` / `values` / `for await`), `FileSystemFileHandle` (`getFile`, `createWritable`, `createSyncAccessHandle` in dedicated workers), `isSameEntry`; kept in `<profile>/opfs/<storage key>/` with names encoded so that names differing by case or reserved by Windows are their own files; `opfs.max_bytes_per_origin` (`QuotaExceededError`), counted by `navigator.storage.estimate()`, removed by "Clear site data".
