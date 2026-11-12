type: Changed

**Faster text offsets**: `length`, `substringData`, `insertData`, `deleteData`, `replaceData` and `splitText` of text nodes find UTF-16 offsets 16 bytes at a time and scan the text once.
