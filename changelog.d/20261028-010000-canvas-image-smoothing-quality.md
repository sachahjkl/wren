type: Added

**Canvas `imageSmoothingQuality`** (`low` / `medium` / `high`): a shrunk image, pattern or `drawImage` is now resampled at the chosen quality on the CPU as well as the GPU, not just with the stored flag. `low` is plain bilinear; `medium` reads one box-filtered level (a mip) so a strong reduction does not alias; `high` builds a full mip pyramid and blends the two levels around the wanted level of detail (trilinear), smooth at any reduction with no level seams. `imageSmoothingEnabled = false` still samples nearest at every quality, and enlarging is bilinear.
