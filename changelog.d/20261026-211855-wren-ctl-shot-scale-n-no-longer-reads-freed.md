type: Fixed

**`wren ctl shot --scale n` no longer reads freed memory.** The picture made by the scaling was released where its block ended, before the PNG was written from it: a capture with a scale other than 1 gave a blank or garbage image, or ended the connection.
