type: Fixed

**`wren ctl shot` works with the wgpu render backend**: a capture used to answer an error there ("this renderer cannot capture its frame"); the toolkit now reads the frame back on both backends (`render.capture_request` / `capture_poll`), so a screenshot from the remote channel (and a headless capture) works whichever backend the build uses.
