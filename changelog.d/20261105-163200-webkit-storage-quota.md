type: Added

**`navigator.webkitTemporaryStorage` and `webkitPersistentStorage`**: `queryUsageAndQuota` and `requestQuota`, from what `navigator.storage.estimate()` says. Sites that read a Chromium User-Agent call them without looking first (cnn.com's private mode detection).
