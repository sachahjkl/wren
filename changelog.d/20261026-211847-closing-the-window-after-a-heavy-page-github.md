type: Fixed

Closing the window after a heavy page (GitHub) could take 5 to 15 s or more: the Wasm module cache wrote every compiled module still queued to its disk cache, each one scanning the folder. It stops after 1.5 s and drops the rest.
