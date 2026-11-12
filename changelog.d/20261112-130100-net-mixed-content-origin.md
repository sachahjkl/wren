type: Security

**Mixed content is blocked in blob:, about:blank and about:srcdoc documents of an https page**: the check now looks at the document's origin, not at its URL. Before, such a document could load scripts, styles and WebSockets over plain http.
