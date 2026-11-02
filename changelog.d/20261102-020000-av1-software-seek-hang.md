type: Fixed

AV1 video decoded by the built-in decoder no longer freezes on a machine short of processors: the decoder was asked for pictures in a way that left its threads waiting for ever with a frame unfinished, and a seek never ended, playback stopped short of the end and closing the page hung. The last pictures of a video are no longer lost when the queue of pictures is full at the end of the data. `media.software.prefer_builtin` plays VP9 and AV1 with the built-in decoders on a machine that has the system's.
