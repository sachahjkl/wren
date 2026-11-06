type: Fixed

**The turns a loading page gives for its first paint are no longer spent in its `<head>`**, where nothing can show: cnn.com painted behind an inline script of 0.9 s and now paints at about 0.55 s instead of 1.6 s. A font of the HTTP cache holds a first paint 100 ms at most, not 500.
