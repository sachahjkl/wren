type: Fixed

**`overflow-wrap: break-word` no longer narrows a box sized to its content**: only `overflow-wrap: anywhere` and `word-break: break-all` / `break-word` let a word break anywhere in its min-content width (CSS Text 3). A box with no room, such as video.js's time tooltip, showed "0:00" one character a line.
