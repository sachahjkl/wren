type: Added

**WebCodecs `VideoDecoder` / `AudioDecoder`** with `EncodedVideoChunk`, `EncodedAudioChunk` and `AudioData`: the decoders wire to the native media pipeline (H.264, VP9, AV1 for video; AAC, MP3, Opus, FLAC for audio) with an honest `isConfigSupported`; `configure`, `decode`, `flush`, `reset`, `close`, `decodeQueueSize`, the `dequeue` event and `output`/`error` callbacks. `AudioData` carries PCM in any `AudioSampleFormat` with planar / interleaved `copyTo`, `allocationSize`, `clone` and `close`.
