type: Fixed

**`document.createCDATASection()`** in XML documents (an XHTML page, `createDocument()`'s, `DOMParser`'s): it makes a CDATA section of that document, serialized as `<![CDATA[...]]>`, and throws `InvalidCharacterError` for data containing `]]>`; an HTML document still refuses it (`NotSupportedError`). It always threw before.
