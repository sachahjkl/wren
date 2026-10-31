# WebCodecs

WebCodecs in Wren is **native**: the pixel model, the sample layouts, the format conversions and the memory accounting
live in the host (Odin), and the decoders wire to the existing media pipeline (`src/media`) and image decoders
(`src/images`). The JavaScript surface is thin glue in `native/js/runtime/web_webcodecs*.c`; no part of the API runs in
interpreted JavaScript.

## What is implemented

| Interface | Where | Notes |
|---|---|---|
| `VideoFrame` | `src/page/webcodecs_frame.odin`, `bindings_webcodecs.odin` | from a canvas / image / video / `ImageBitmap` / `OffscreenCanvas` / `VideoFrame` / `BufferSource`; `copyTo`, `allocationSize`, `visibleRect`, `colorSpace`, `clone`, `close`; drawable and transferable |
| `VideoColorSpace` | `web_webcodecs.c` | the four nullable members, `toJSON` |
| `ImageDecoder`, `ImageTrackList`, `ImageTrack` | `bindings_image_decoder.odin` | decodes with `src/images`; `decode({frameIndex})`, `tracks`, honest `isTypeSupported` |
| `EncodedVideoChunk`, `EncodedAudioChunk` | `webcodecs_chunks.odin` | immutable coded samples; `copyTo`, `byteLength` |
| `AudioData` | `webcodecs_chunks.odin` | PCM in any `AudioSampleFormat`; planar / interleaved `copyTo`, `allocationSize`, `clone`, `close` |
| `VideoDecoder` | `bindings_video_decoder.odin` | wires to `src/media` (H.264, VP9, AV1); honest `isConfigSupported` |
| `AudioDecoder` | `bindings_audio_decoder.odin` | wires to `src/media` (AAC, MP3, Opus, FLAC) |
| `VideoEncoder`, `AudioEncoder` | `bindings_encoders.odin` | honest: no encoder is linked, so `isConfigSupported` is `false` and `configure` raises `NotSupportedError` |

## Memory and preferences

Every frame, chunk and `AudioData` is charged against `page.max_fetch_bytes`, like any other buffer, and freed with the
object or the page. `about:config`:

- `webcodecs.enabled` — the whole API (off hides the interfaces).
- `webcodecs.max_frame_bytes` — the pixels (or samples) of one `VideoFrame` / `AudioData`.
- `webcodecs.max_dimension` — the largest side of a `VideoFrame`.
- `webcodecs.max_decode_queue` — the most encoded chunks a decoder may have queued (`decodeQueueSize`).
- `webcodecs.allow_encoders` — the encoders (always honest-unsupported today).

## Notes and limits

- **`VideoDecoder` output needs CPU planes.** The software decoders (VP9, AV1) produce CPU planes that are wrapped
  directly as I420 / NV12 `VideoFrame`s. A GPU-only picture (DXVA H.264 into a Direct3D texture) cannot be read back
  from the page layer; `configure` asks the backend for a software decoder, and a decoded picture that still has no CPU
  planes is reported through the `error` callback. A software H.264 path (or a GPU read-back) would lift this.
- **The decode is synchronous on the page thread** (the inputs are bounded and the built-in decoders are
  memory-safe); the `decode`/`flush` promises and the `output` callbacks still run as their own event-loop turns.
- **`VideoFrame` transfer across realms** (`postMessage` to a worker) moves the pixels through a process-wide host
  token (`VideoFrame_takeForTransfer` / `adoptTransfer`), wired into structured clone (`native/js/odin/clone.odin`): the pixels never cross a heap boundary as a JS value.
- **`ImageDecoder` `data`** accepts a `BufferSource` or a `Blob`; a `ReadableStream` source is not read here (read it
  to bytes first).
- **Encoders** are intentionally unsupported until a pure-Rust encoder (rav1e, a VP8/VP9 encoder, or an Opus encoder)
  is added to `native/Cargo.toml`; `bindings_encoders.odin` is the single place to wire it.
