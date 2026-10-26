type: Changed

**`remote_e2e.ps1`: the video-layers check costs a third of the frames, and the check build's run barely any** (`--settle 0`: each capture is the very next frame drawn instead of the third one after the request, 30 frames in a row instead of 40 spread three apart, each compared with the one before; `-Check`, which looks for leaks, takes 6): the section was 80 s of the 115 s of the step on the CI and 35 s of the 68 s of `-Check`; here 5.7 s to 2.8 s, and `-Check` 17.9 s to 12.5 s.
