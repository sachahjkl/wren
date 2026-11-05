type: Fixed

**A text edited in the developer tools no longer paints garbage for a frame**: the edit lands after the page was prepared and before it is painted, and the paint read the text that was just freed. A page or a frame whose document changed since its layout is laid out again first; a drag picture is not made from such a layout.
