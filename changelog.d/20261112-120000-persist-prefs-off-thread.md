type: Changed

**Saving the preferences no longer pauses the interface**: `prefs.txt` is written by a background thread like the other profile files, and only when a preference changed; at exit it is written before Wren ends.
