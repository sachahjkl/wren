type: Fixed

**A crash on pages whose scripts read styles while a link loads** (an access violation reading 0xFFFFFFFFFFFFFFFF, imdb.com): a layout's display list points at the records of its style pass, and a later pass with no layout after it took them away from a frame still painted or hit tested. A layout now keeps the pass it reads as long as it stands (`style.styled_read_begin`), whatever the page does meanwhile; the held frame stays on screen through such a pass instead of giving way to the page's background.
