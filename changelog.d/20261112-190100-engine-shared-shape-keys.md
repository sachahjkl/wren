type: Changed

**Objects built key by key use less memory**: the hidden classes that a script makes when it adds properties one by one now share one list of keys, so an object of n keys no longer copies 1 + 2 + … + n keys.
