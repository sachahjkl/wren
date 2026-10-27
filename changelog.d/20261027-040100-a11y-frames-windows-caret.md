type: Added

**Screen readers read the documents of frames, the caret of page fields, and each window's own page**:
  - an iframe's document is a tree of its own grafted under its element (its buttons, links and fields act in the frame);
  - a text field of a page gives its caret and selection, words and characters (UI Automation's text pattern), and a selection made by the reader moves the page's;
  - every window keeps its page's tree (`Window_Own.a11y`): two windows show two pages; `Browser.getWindows` gives each window's `hwnd`.
