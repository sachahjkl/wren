type: Changed

**Faster stylesheet parsing with less memory**: the CSS tokenizer reads the sheet's bytes directly, 16 at a time for comments, whitespace, names and strings, and the names and strings without escapes point into the sheet's own text instead of being copied.
