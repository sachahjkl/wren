type: Fixed

**Percentage heights in quirks mode follow the window**: on a page without a doctype, a box whose height is a percentage now takes its new height when the window becomes taller or shorter, or when the height of an ancestor it depends on changes. Before, it could keep the height of the previous size.
