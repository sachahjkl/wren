type: Fixed

**`Range.createContextualFragment()` scripts run once inserted** (`Range_createContextualFragment`, parsed natively with the range's context element): a script the markup leaves open never runs, and a clone of a script element keeps its "already started" flag (`cloneNode`, `importNode`), so a clone of a script set by `innerHTML` does not run either.
