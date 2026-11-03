type: Fixed

**Text, comments, fragments and processing instructions of a document of its own are its**: what `createTextNode`, `createComment`, `createDocumentFragment` and `createProcessingInstruction` of a document of its own (`createHTMLDocument`'s, `new Document()`, `DOMParser`'s) make has that document as `ownerDocument`, as its elements already had.