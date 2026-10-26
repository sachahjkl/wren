type: Added

**`webkitGetAsEntry()`**: `FileSystemEntry`, `FileSystemFileEntry` (`file()`), `FileSystemDirectoryEntry` (`createReader()`, `getFile`, `getDirectory`), `FileSystemDirectoryReader` (`readEntries()` in batches of 100), `getParent`, `filesystem.name` for dropped files and folders, listed and opened lazily on a background thread, paths kept inside what was dropped (`src/page/dnd_entries.odin`, `native/js/runtime/web_entries.c`). (`getAsFileSystemHandle` is not exposed: Wren has no `FileSystemHandle`.)
