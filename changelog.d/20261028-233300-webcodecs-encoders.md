type: Added

**WebCodecs `VideoEncoder` / `AudioEncoder`** (`webcodecs.allow_encoders`): the interfaces exist so feature detection and construction behave, but no encoder is linked in this build, so `isConfigSupported` honestly reports `{ supported: false }` and `configure` raises `NotSupportedError` (the single place to wire a future encoder crate).
