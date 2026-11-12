type: Changed

**ConvolverNode with long impulse responses** (`webaudio.max_convolver_seconds`): the work per sample grows with the logarithm of the impulse response, not with its length, so long reverbs no longer overload the audio thread. Only the first 20 seconds of an impulse response are used (the preference changes it).
