type: Fixed

**Attr nodes have a document**: `attr.ownerDocument` is the document that made it, or its element's (it follows an element moved to another document), where it was always `null`; `cloneNode()` and `importNode()` copy an Attr; `createAttributeNS()` checks its qualified name as `createElementNS()` does (`"p:"` throws `InvalidCharacterError`); appending another window's document throws `HierarchyRequestError`, not a `SecurityError`.
