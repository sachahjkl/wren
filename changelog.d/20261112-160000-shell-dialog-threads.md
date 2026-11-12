type: Fixed

**A file dialog no longer holds the browser's background work**: the Save, Open and folder dialogs (Save as, file inputs, colour inputs, the File System Access pickers, the content blocker's import and export) each run on a thread of their own. File reads and other dialogs no longer wait until you answer, and closing Wren with a dialog open no longer waits for it.
