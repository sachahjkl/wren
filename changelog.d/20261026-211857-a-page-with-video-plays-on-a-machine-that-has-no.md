type: Fixed

**A page with video plays on a machine that has no audio device** (a server, a CI runner, a remote session without sound): the player used to stop with a media error (`the audio device is gone`). It now gets an output that lets the audio go by in silence at the pace of the clock (`src/media/audio_null_windows.odin`), so the media clock follows it as usual and the video plays, as in the browsers.
