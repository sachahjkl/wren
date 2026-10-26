type: Added

**`FileSystemWritableFileStream`**: `write` (BufferSource, Blob, string, `{type: "write" | "seek" | "truncate"}`), `seek`, `truncate`, `close` replaces the file in one rename from a temporary file, `abort` leaves it; a sync access handle (`read`, `write`, `truncate`, `getSize`, `flush`, `close`) writes in place under an exclusive lock; a locked entry cannot be removed (`NoModificationAllowedError`).
