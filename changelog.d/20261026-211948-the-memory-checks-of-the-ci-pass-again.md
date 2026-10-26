type: Fixed

**The memory checks of the CI pass again** (`src/page/pointer_input.odin`, `dnd_session.odin`, `page.odin`): the pointer state and the drag session of a page were kept in two tables of the process (`map[^Page]`), whose own memory (320 bytes each) was never given back, and which pages on several threads shared. They are fields of the page now, freed when it closes: `jsdomtest` and the check build of `remote_e2e` report 0 leaked blocks (they reported 2 and 1).
