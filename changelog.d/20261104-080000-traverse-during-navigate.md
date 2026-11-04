type: Fixed

**Navigation API**: `navigation.traverseTo()` or `back()` called while the `navigate` event of a history traversal is being handled now runs once that traversal is done, toward the entry asked for, instead of moving by the distance measured before it (it went one entry too far, or to the first one).
