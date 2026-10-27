type: Fixed

**The canvas2d unit tests no longer race on one outline** (src/canvas2d/canvas2d_test.odin): two tests drew with a shared fake glyph outline and each freed it at its end, so with several test threads (the CI's four) one could draw while the other freed it.
