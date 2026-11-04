type: Fixed

**Developer tools: a crash in the console.** A navigation (or the limit of lines) under an open Console, with a line said before the next frame, left rows pointing past the end of the list: a bounds check in `console_panel`, 0.6.28.
