type: Fixed

**Inline event handlers of cloned elements**: an element made by `cloneNode()` or `document.importNode()` (a `<template>`'s contents stamped into the page, a row copied from another) runs its `onclick="..."`, `onsubmit="..."` and other handler attributes; they did nothing before, and its `onclick` property was `null`.
