type: Fixed

**Text tracks** (`HTMLMediaElement.addTextTrack`) : an invalid `kind` throws a TypeError, as the TextTrackKind Web IDL enum requires, instead of being silently coerced to `"subtitles"`. Unknown values, a wrong case such as `"SUBTITLES"`, and the strings a missing or null argument converts to are all rejected; the `<track>` element keeps its own forgiving default.
