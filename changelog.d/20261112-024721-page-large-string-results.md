type: Changed

**Large strings are made once**: `innerHTML`, `outerHTML`, `textContent` and the other strings larger than the script's buffer are computed once, not twice.
