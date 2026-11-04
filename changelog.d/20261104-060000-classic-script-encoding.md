type: Fixed

**Scripts in legacy encodings**: an external classic script is decoded from its byte order mark, its Content-Type charset, its `charset` attribute or the document's encoding (windows-1250, Shift_JIS...) instead of always as UTF-8, where it failed with "invalid UTF-8 sequence".
