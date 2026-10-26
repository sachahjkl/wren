type: Changed

Files given to a page (dropped, chosen in `<input type=file>`) are read on demand by slice (`File.slice().arrayBuffer()` reads only that part); `HTMLInputElement.files` and `input.files = dataTransfer.files` work.
