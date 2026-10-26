type: Added

**A button to copy the licence details** (about:wren, under the card: `Copy the licence details`): plain text with the edition, the name, the e-mail, the issue date and the order number, never the key. One click handler, `navigator.clipboard.writeText`, the label says `Copied` for a moment; if the write is refused the text is shown selected in a read-only field. Every field travels in an escaped attribute.
