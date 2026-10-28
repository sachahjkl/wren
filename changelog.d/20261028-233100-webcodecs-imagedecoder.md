type: Added

**WebCodecs `ImageDecoder`** (`ImageTrackList`, `ImageTrack`): decodes PNG, JPEG, GIF, WebP, AVIF, BMP, ICO and TIFF (animations included) into `VideoFrame`s with the built-in decoders; `decode({frameIndex})`, `tracks`, `type`, `complete`, `completed`, `reset`, `close` and an honest static `isTypeSupported`. `ImageTrack` reports `frameCount`, `animated` and `repetitionCount`.
