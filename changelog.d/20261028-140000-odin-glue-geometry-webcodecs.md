type: Changed

**Geometry and WebCodecs glue in Odin** (`native/js/odin/web_geometry.odin`, `web_webcodecs*.odin`, `api_decl/webcodecs.odin`): DOMPoint / DOMMatrix / DOMQuad and VideoFrame, VideoColorSpace, ImageDecoder, the decoders, the encoded chunks, AudioData and the encoders leave the C glue; the host calls of WebCodecs are declared once and bound through `jsb` (a getter that only carries a value is one line), the decoders share one callback table.
