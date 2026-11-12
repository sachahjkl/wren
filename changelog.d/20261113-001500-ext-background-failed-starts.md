type: Fixed

**An extension's background that fails before it runs is no longer started again for each event** (`extensions.background.failed_starts_max`, 3 by default): past that many failed starts in a row it stays stopped until the extension is reloaded, and a message sent to it fails at once. A message that such a background was to answer now gets its answer instead of waiting for ever.
