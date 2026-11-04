type: Security

**Errors of another origin's script are muted**: an uncaught error of a classic script fetched from another origin without CORS reaches `window.onerror` as `Script error.` with no file, line or error object, as in other browsers; and a `data:` URL holding parentheses is the whole file name of its script's errors.
