// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=webcodecs order=69 exposed=(Window,Worker)
/// WebCodecs (src/page/bindings_webcodecs.odin, webcodecs_frame.odin): the pixel model, memory accounting and format
/// conversions of a VideoFrame are native. The engine (native/js/runtime/web_webcodecs.c) holds the VideoFrame
/// wrapper, builds the VideoFrameInit / VideoFrameBufferInit / VideoFrameCopyToOptions dictionaries, resolves copyTo's
/// promise and transfers the handle in a postMessage. A VideoFrame is a host object (OBJECT_TAG); drawImage and
/// createImageBitmap resolve it through the canvas image-source path. Decoders and encoders come in later modules.
package api_webcodecs

//@wb handle parent=Object host=Video_Frame_Obj lookup=lookup_VideoFrame
VideoFrame :: distinct Handle

/// WebCodecs VideoPixelFormat, in the order webcodecs_frame.odin's Frame_Format uses (format() returns -1 for a
/// closed frame, which the engine maps to null).
VideoPixelFormat :: enum i32 {
	None,
	I420,
	I420A,
	I422,
	I444,
	NV12,
	RGBA,
	RGBX,
	BGRA,
	BGRX,
}

/// /////////////////////////////
/// new VideoFrame(image, init): build from a drawable source (an element handle img / canvas / video, or an object
/// handle ImageBitmap / OffscreenCanvas / VideoFrame). The source's pixels are captured now. `timestamp` (microseconds)
/// is required for a source without an intrinsic one; `has_ts` says it was given. Invalid_State when the source has no
/// pixels (not loaded, empty, a GPU-only video), Quota when it is too large, Not_Supported when WebCodecs is off.
//@wb fn raises owned
VideoFrame_fromImage :: proc(source: u64, timestamp: i64, has_ts: bool, duration: i64, has_duration: bool) -> VideoFrame

/// new VideoFrame(bufferSource, init): build from raw pixel bytes with a VideoFrameBufferInit. `format`, `coded_w`,
/// `coded_h` and `timestamp` are required (the engine checks). `has_visible` / `has_display` carry the optional
/// visibleRect and displaySize; a custom plane layout gives `layout_offsets` / `layout_strides` (one per plane) when
/// `has_layout`. Colour space members are -1 when absent; `cp_has` says a colorSpace was given at all.
//@wb fn raises owned
VideoFrame_fromBuffer :: proc(data: bytes, format: VideoPixelFormat, coded_w: i32, coded_h: i32, timestamp: i64, duration: i64, has_duration: bool, vis_x: i32, vis_y: i32, vis_w: i32, vis_h: i32, has_visible: bool, display_w: i32, display_h: i32, has_display: bool, layout_offsets: []i32, layout_strides: []i32, has_layout: bool, cp_prim: i32, cp_trans: i32, cp_matrix: i32, cp_full: i32, cp_has: i32) -> VideoFrame

/// /////////////////////////////
/// frame.format: -1 (null) for a closed frame.
//@wb fn
VideoFrame_format :: proc(frame: VideoFrame) -> i32

//@wb fn
VideoFrame_codedWidth :: proc(frame: VideoFrame) -> u32

//@wb fn
VideoFrame_codedHeight :: proc(frame: VideoFrame) -> u32

//@wb fn
VideoFrame_displayWidth :: proc(frame: VideoFrame) -> u32

//@wb fn
VideoFrame_displayHeight :: proc(frame: VideoFrame) -> u32

/// frame.timestamp / duration, in microseconds (duration is -1 when the frame has none, which the engine maps to null).
//@wb fn
VideoFrame_timestamp :: proc(frame: VideoFrame) -> i64

//@wb fn
VideoFrame_duration :: proc(frame: VideoFrame) -> i64

/// frame.visibleRect: `which` 0..3 selects x, y, width, height. -1 for a closed frame (null).
//@wb fn
VideoFrame_visibleRect :: proc(frame: VideoFrame, which: i32) -> f64

/// frame.colorSpace: which selects primaries (0), transfer (1), matrix (2) or full-range (3); -1 means null (absent),
/// else the enum index (VideoColorPrimaries / VideoTransferCharacteristics / VideoMatrixCoefficients) or the bool.
//@wb fn
VideoFrame_colorSpace :: proc(frame: VideoFrame, which: i32) -> i32

/// Whether the frame has been closed (its pixels freed).
//@wb fn
VideoFrame_isClosed :: proc(frame: VideoFrame) -> bool

/// /////////////////////////////
/// frame.allocationSize(options): the bytes copyTo needs. `format` -1 keeps the frame's own; `has_rect` gives a crop
/// rectangle; a custom layout's strides are honoured when `has_layout`.
//@wb fn raises
VideoFrame_allocationSize :: proc(frame: VideoFrame, format: i32, rx: i32, ry: i32, rw: i32, rh: i32, has_rect: bool, layout_offsets: []i32, layout_strides: []i32, has_layout: bool) -> i32

/// frame.copyTo(destination, options): copies the frame (or its crop rectangle) into `dst` as `format` (-1 = own).
/// The plane layout used is kept on the frame (read it with VideoFrame_copyLayout); the return is the plane
/// count. The engine wraps this in a promise resolving to a PlaneLayout[]. Range for a rectangle outside the picture,
/// Not_Supported for an unsupported conversion, Invalid_State for a closed frame.
//@wb fn raises out=dst
VideoFrame_copyTo :: proc(frame: VideoFrame, dst: bytes, format: i32, rx: i32, ry: i32, rw: i32, rh: i32, has_rect: bool, in_offsets: []i32, in_strides: []i32, has_layout: bool) -> i32

/// The plane layout the last copyTo of `frame` used: `which` 0 is the offset, 1 the stride, of plane `plane`.
//@wb fn
VideoFrame_copyLayout :: proc(frame: VideoFrame, plane: i32, which: i32) -> i32

/// /////////////////////////////
/// frame.clone(): a new VideoFrame sharing the timing, with its own copy of the pixels.
//@wb fn raises owned
VideoFrame_clone :: proc(frame: VideoFrame) -> VideoFrame

/// frame.close(): free the pixels; the handle stays valid but closed.
//@wb fn
VideoFrame_close :: proc(frame: VideoFrame)

/// postMessage transfer within one realm: move the pixels into a new object (owner = the receiving realm's instance),
/// closing the original. Data_Clone when it is already detached.
//@wb fn raises
VideoFrame_transfer :: proc(frame: VideoFrame, owner: u32) -> VideoFrame

/// Cross-realm transfer (postMessage to a worker): the source realm detaches the frame into a process-wide token;
/// the destination realm adopts it. The pixels stay host-owned throughout. Both are used by structured clone
/// (native/js/runtime/clone.c). takeForTransfer returns 0 when the frame is already closed; adoptTransfer returns 0
/// when the token is unknown or the destination is over its memory budget.
//@wb fn
VideoFrame_takeForTransfer :: proc(frame: VideoFrame) -> u64

//@wb fn
VideoFrame_adoptTransfer :: proc(token: u64) -> VideoFrame

