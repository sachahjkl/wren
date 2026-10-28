// The 2D canvas domain (module canvas of api/canvas.widl): the calls the hand-written members of web_canvas.odin make
// (getContext, the encoders, styles, transforms, paths, text, ImageData, drawImage, createImageBitmap). The members
// the bindings generator already binds (fillRect, lineWidth...) are not repeated here. Declared from today's generated
// wr_* imports: a `has_*` flag that follows its value on the wire is a separate bool; a `_ret` slot is the value of a
// (value, Api_Error) result.
package api_decl

import "../abi"

HTMLCanvasElement                 :: distinct abi.Handle
// A CanvasRenderingContext2D or an OffscreenCanvasRenderingContext2D (the host's wr_CanvasRenderingContext2D).
CanvasRenderingContext2D          :: distinct abi.Handle
OffscreenCanvasRenderingContext2D :: distinct abi.Handle
OffscreenCanvas                   :: distinct abi.Handle
ImageBitmapRenderingContext       :: distinct abi.Handle
ImageBitmap                       :: distinct abi.Handle
CanvasGradient                    :: distinct abi.Handle
CanvasPattern                     :: distinct abi.Handle
Path2D                            :: distinct abi.Handle

// What a fill or stroke style currently is.
CanvasStyleKind :: enum i32 { Color, Gradient, Pattern }

// getContext("2d", {alpha, willReadFrequently}) / getContext("bitmaprenderer", {alpha}): 0 when the canvas already has
// a context of another kind.
HTMLCanvasElement_context2d      :: #type proc(canvas: HTMLCanvasElement, alpha: bool, will_read_frequently: bool) -> (CanvasRenderingContext2D, abi.Api_Error)
HTMLCanvasElement_bitmapRenderer :: #type proc(canvas: HTMLCanvasElement, alpha: bool) -> (ImageBitmapRenderingContext, abi.Api_Error)
OffscreenCanvas_context2d        :: #type proc(canvas: OffscreenCanvas, alpha: bool, will_read_frequently: bool) -> (OffscreenCanvasRenderingContext2D, abi.Api_Error)
OffscreenCanvas_bitmapRenderer   :: #type proc(canvas: OffscreenCanvas, alpha: bool) -> (ImageBitmapRenderingContext, abi.Api_Error)
OffscreenCanvas_create           :: #type proc(width: u64, height: u64) -> (abi.Owned(OffscreenCanvas), abi.Api_Error)
CanvasSettings_alpha              :: #type proc(ctx: CanvasRenderingContext2D) -> bool
CanvasSettings_willReadFrequently :: #type proc(ctx: CanvasRenderingContext2D) -> bool
ImageBitmapRenderingContext_transferFromImageBitmap :: #type proc(ctx: ImageBitmapRenderingContext, bitmap: u64, has_bitmap: bool) -> abi.Api_Error

// The canvas (an element or an OffscreenCanvas handle) encoded as `type` (image/png or image/jpeg; quality -1: the
// default): a Buffer (0 for a canvas with no pixels), released by the caller.
Canvas_encode :: #type proc(canvas: u64, type: string, quality: f64) -> (u64, abi.Api_Error)

CanvasStyle_kind      :: #type proc(ctx: CanvasRenderingContext2D, stroke: bool) -> CanvasStyleKind
CanvasStyle_color     :: #type proc(ctx: CanvasRenderingContext2D, stroke: bool) -> string
// the gradient or pattern of the style (borrowed: its wrapper owns it)
CanvasStyle_object    :: #type proc(ctx: CanvasRenderingContext2D, stroke: bool) -> u64
CanvasStyle_setColor  :: #type proc(ctx: CanvasRenderingContext2D, stroke: bool, color: string) -> abi.Api_Error
CanvasStyle_setObject :: #type proc(ctx: CanvasRenderingContext2D, stroke: bool, object: u64)
// Not_Found: the image is not ready (createPattern returns null)
Canvas_createPattern  :: #type proc(ctx: CanvasRenderingContext2D, source: u64, repetition: string) -> (abi.Owned(CanvasPattern), abi.Api_Error)

CanvasTransform_setTransform     :: #type proc(ctx: CanvasRenderingContext2D, m11, m12, m21, m22, m41, m42: f64)
CanvasTransform_matrixElement    :: #type proc(ctx: CanvasRenderingContext2D, index: i32) -> f64
CanvasPattern_setTransformMatrix :: #type proc(pattern: CanvasPattern, m11, m12, m21, m22, m41, m42: f64)

// `path` 0: the context's current path
CanvasDrawPath_fill            :: #type proc(ctx: CanvasRenderingContext2D, path: u64, rule: string)
CanvasDrawPath_stroke          :: #type proc(ctx: CanvasRenderingContext2D, path: u64)
CanvasDrawPath_clip            :: #type proc(ctx: CanvasRenderingContext2D, path: u64, rule: string)
CanvasDrawPath_isPointInPath   :: #type proc(ctx: CanvasRenderingContext2D, path: u64, x: f64, y: f64, rule: string) -> bool
CanvasDrawPath_isPointInStroke :: #type proc(ctx: CanvasRenderingContext2D, path: u64, x: f64, y: f64) -> bool

CanvasPathDrawingStyles_setLineDash   :: #type proc(ctx: CanvasRenderingContext2D, segments: []f64)
CanvasPathDrawingStyles_lineDashCount :: #type proc(ctx: CanvasRenderingContext2D) -> i32
CanvasPathDrawingStyles_lineDashAt    :: #type proc(ctx: CanvasRenderingContext2D, index: i32) -> f64

// `target`: a context (its current path) or a Path2D; radii: 4 (x, y) pairs, top-left first
CanvasPath_roundRect :: #type proc(target: u64, x, y, w, h: f64, radii: []f64) -> abi.Api_Error
// new Path2D(path?) / new Path2D(svg): `from` 0 when not a copy
Path2D_create        :: #type proc(from: u64, svg: string) -> Path2D
Path2D_addPath       :: #type proc(target: Path2D, path: Path2D, m11, m12, m21, m22, m41, m42: f64)

CanvasText_fillText   :: #type proc(ctx: CanvasRenderingContext2D, text: string, x: f64, y: f64, max_width: f64, has_max: bool)
CanvasText_strokeText :: #type proc(ctx: CanvasRenderingContext2D, text: string, x: f64, y: f64, max_width: f64, has_max: bool)

// The largest ImageData a script may make or read back, in bytes (canvas.max_image_data_bytes).
CanvasImageData_maxBytes :: #type proc() -> u64
CanvasImageData_get      :: #type proc(ctx: CanvasRenderingContext2D, x, y, w, h: i32, data: []u8) -> abi.Api_Error
CanvasImageData_put      :: #type proc(ctx: CanvasRenderingContext2D, data: []u8, data_w, data_h, dx, dy, dirty_x, dirty_y, dirty_w, dirty_h: i32)

// form 2, 4 or 8: drawImage's (dx, dy), (dx, dy, dw, dh) or (sx, sy, sw, sh, dx, dy, dw, dh)
CanvasDrawImage_drawImage :: #type proc(ctx: CanvasRenderingContext2D, source: u64, form: i32, sx, sy, sw, sh, dx, dy, dw, dh: f64) -> abi.Api_Error

// createImageBitmap: from straight RGBA8 pixels, or from a source (form 4: the (sx, sy, sw, sh) crop). The options
// are integers (ImageBitmapOptions as api/canvas.widl numbers them).
Canvas_bitmapFromPixels :: #type proc(data: []u8, width, height, orient, premul, colorspace, resize_w, resize_h, resize_q: i32) -> (abi.Owned(ImageBitmap), abi.Api_Error)
Canvas_createBitmap     :: #type proc(source: u64, form: i32, sx, sy, sw, sh: f64, orient, premul, colorspace, resize_w, resize_h, resize_q: i32) -> (abi.Owned(ImageBitmap), abi.Api_Error)
// A Blob's bytes (a Buffer) decoded on the decoding threads: a promise of the RGBA pixels (a Buffer) with "WxH" as text.
Image_decode :: #type proc(data: u64) -> u64
