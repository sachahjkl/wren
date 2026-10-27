type: Added

**A built-in AV1 video decoder for the media player** (`media.software.threads`) : rav1d, already linked for AVIF images, decodes AV1 video behind the player's decoder interface (pictures in memory, I420 or 10-bit, held without a copy until shown); it is the AV1 decoder of Linux, where `<video>` now plays AV1 (audio still goes by silently there until the audio backend lands). Windows keeps Media Foundation.
