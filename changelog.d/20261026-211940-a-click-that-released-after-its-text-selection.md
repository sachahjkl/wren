type: Fixed

**A click that released after its text selection gesture was started no longer selects text as the mouse moves** (`selection_shell.odin`, `main.odin`): a press that waited for a fresh layout (a page that changes its DOM on `mousedown`, YouTube's thumbnails) was started a frame later, after the release had come and gone, so the gesture stayed open with the button up and every move selected text. The release now drops a waiting press, and it is taken before the checks that could skip it.
