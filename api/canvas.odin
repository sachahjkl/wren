// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=canvas order=4 exposed=(Window,Worker)
/// Canvas 2D (HTML §4.12.5): the 2D rendering context of <canvas> and OffscreenCanvas, drawn by a software rasterizer
/// (package canvas2d) into a premultiplied RGBA8 bitmap that the shell shows as a texture, updated only when the
/// drawing changed. Members shared by CanvasRenderingContext2D and OffscreenCanvasRenderingContext2D are one function
/// imported under their mixin's name (CanvasState_save...); those of CanvasPath work on a context's current path or on a
/// Path2D alike (CanvasPathTarget). Arguments that are NaN or infinite make a drawing or path call do nothing (the
/// specification's rule); an enum given an invalid string leaves the attribute as it was.
/// * colors are CSS color strings, parsed by the browser's CSS parser (`currentcolor` is the canvas element's color);
/// fillStyle / strokeStyle read back as `#rrggbb` or `rgba(r, g, b, a)`;
/// * pixel data (ImageData) is straight-alpha RGBA8, rows top to bottom;
/// * a canvas that drew an image the page may not read (cross-origin without CORS) is tainted: reading it back
/// (getImageData, toDataURL, toBlob...) raises Security;
/// * workers have OffscreenCanvas (drawn in the worker's thread; its text is not drawn yet: the shell's fonts belong to
/// the interface thread); functions taking an element answer as for a dead handle there.
package api_canvas

//@wb handle parent=Element host=dom.Node lookup=lookup_HTMLCanvasElement
HTMLCanvasElement :: distinct Handle

//@wb handle parent=Object host=Canvas_Obj lookup=lookup_CanvasRenderingContext2D
/// A CanvasRenderingContext2D or an OffscreenCanvasRenderingContext2D.
CanvasRenderingContext2D :: distinct Handle

//@wb handle parent=Object host=Canvas_Obj lookup=lookup_CanvasPathTarget
/// The target of the CanvasPath members: a context (its current path) or a Path2D.
CanvasPathTarget :: distinct Handle

//@wb handle parent=Object host=Canvas_Obj lookup=lookup_CanvasGradient
CanvasGradient :: distinct Handle

//@wb handle parent=Object host=Canvas_Obj lookup=lookup_CanvasPattern
CanvasPattern :: distinct Handle

//@wb handle parent=Object host=Canvas_Obj lookup=lookup_Path2D
Path2D :: distinct Handle

//@wb handle parent=Object host=Canvas_Obj lookup=lookup_TextMetrics
TextMetrics :: distinct Handle

//@wb handle parent=Object host=Canvas_Obj lookup=lookup_OffscreenCanvas
OffscreenCanvas :: distinct Handle

//@wb handle parent=Object host=Canvas_Obj lookup=lookup_ImageBitmap
ImageBitmap :: distinct Handle

//@wb handle parent=Object host=Canvas_Obj lookup=lookup_ImageBitmapRenderingContext
ImageBitmapRenderingContext :: distinct Handle

/// What a fill or stroke style currently is.
StyleKind :: enum i32 {
	Color,
	Gradient,
	Pattern,
}

/// /////////////////////////////
/// canvas.width: the `width` attribute as HTML parses it (a non-negative integer, 300 when absent or invalid).
//@wb fn
HTMLCanvasElement_width :: proc(canvas: HTMLCanvasElement) -> u32

/// canvas.width = n: sets the attribute and resets the canvas (cleared, context state back to the default).
//@wb fn
HTMLCanvasElement_set_width :: proc(canvas: HTMLCanvasElement, value: u32)

/// canvas.height: 150 when absent or invalid.
//@wb fn
HTMLCanvasElement_height :: proc(canvas: HTMLCanvasElement) -> u32

//@wb fn
HTMLCanvasElement_set_height :: proc(canvas: HTMLCanvasElement, value: u32)

/// getContext("2d", { alpha, willReadFrequently }): the canvas's 2D context, made on the first call (the bitmap is
/// allocated then) and the same object afterwards. `alpha` false: an opaque canvas (black until drawn on). Quota when
/// the size is over canvas.max_dimension / canvas.max_pixels or the page's canvas memory (canvas.max_page_bytes).
//@wb fn raises
HTMLCanvasElement_context2d :: proc(canvas: HTMLCanvasElement, alpha: bool, will_read_frequently: bool) -> CanvasRenderingContext2D

/// The canvas (an element, or an OffscreenCanvas handle) encoded as `type`: "image/png", or "image/jpeg" at `quality`
/// (0 to 1; outside it the default, canvas.encode.jpeg_quality). Security when the canvas is tainted. An empty buffer
/// for a canvas with no pixels (width or height 0).
//@wb fn raises
Canvas_encode :: proc(canvas: u64, type: string, quality: f64) -> Buffer

/// /////////////////////////////
/// context.canvas
//@wb fn
CanvasRenderingContext2D_canvas :: proc(ctx: CanvasRenderingContext2D) -> HTMLCanvasElement

/// OffscreenCanvasRenderingContext2D.canvas
//@wb fn
OffscreenCanvasRenderingContext2D_canvas :: proc(ctx: CanvasRenderingContext2D) -> OffscreenCanvas

/// getContextAttributes().alpha / .willReadFrequently
//@wb fn
CanvasSettings_alpha :: proc(ctx: CanvasRenderingContext2D) -> bool

//@wb fn
CanvasSettings_willReadFrequently :: proc(ctx: CanvasRenderingContext2D) -> bool

/// save(): ignored once canvas.max_save_depth states are saved.
//@wb fn
CanvasState_save :: proc(ctx: CanvasRenderingContext2D)

//@wb fn
CanvasState_restore :: proc(ctx: CanvasRenderingContext2D)

/// reset(): clears the canvas and puts every attribute back.
//@wb fn
CanvasState_reset :: proc(ctx: CanvasRenderingContext2D)

/// Always false: the software canvas is not lost.
//@wb fn
CanvasState_isContextLost :: proc(ctx: CanvasRenderingContext2D) -> bool

//@wb fn
CanvasTransform_scale :: proc(ctx: CanvasRenderingContext2D, x: f64, y: f64)

//@wb fn
CanvasTransform_rotate :: proc(ctx: CanvasRenderingContext2D, angle: f64)

//@wb fn
CanvasTransform_translate :: proc(ctx: CanvasRenderingContext2D, x: f64, y: f64)

//@wb fn
CanvasTransform_transform :: proc(ctx: CanvasRenderingContext2D, m11: f64, m12: f64, m21: f64, m22: f64, m41: f64, m42: f64)

//@wb fn
CanvasTransform_setTransform :: proc(ctx: CanvasRenderingContext2D, m11: f64, m12: f64, m21: f64, m22: f64, m41: f64, m42: f64)

//@wb fn
CanvasTransform_resetTransform :: proc(ctx: CanvasRenderingContext2D)

/// One element of the current transform: 0 to 5 are a, b, c, d, e, f.
//@wb fn
CanvasTransform_matrixElement :: proc(ctx: CanvasRenderingContext2D, index: i32) -> f64

//@wb fn
CanvasCompositing_globalAlpha :: proc(ctx: CanvasRenderingContext2D) -> f64

/// Outside 0 to 1, or NaN: ignored.
//@wb fn
CanvasCompositing_set_globalAlpha :: proc(ctx: CanvasRenderingContext2D, value: f64)

//@wb fn
CanvasCompositing_globalCompositeOperation :: proc(ctx: CanvasRenderingContext2D) -> string

/// source-over, source-in, source-out, source-atop, destination-over / -in / -out / -atop, lighter, copy, xor, and the
/// blend modes multiply, screen, overlay, darken, lighten, color-dodge, color-burn, hard-light, soft-light, difference,
/// exclusion, hue, saturation, color, luminosity. Anything else is ignored.
//@wb fn
CanvasCompositing_set_globalCompositeOperation :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasImageSmoothing_imageSmoothingEnabled :: proc(ctx: CanvasRenderingContext2D) -> bool

//@wb fn
CanvasImageSmoothing_set_imageSmoothingEnabled :: proc(ctx: CanvasRenderingContext2D, value: bool)

//@wb fn
CanvasImageSmoothing_imageSmoothingQuality :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasImageSmoothing_set_imageSmoothingQuality :: proc(ctx: CanvasRenderingContext2D, value: string)

/// Which kind of style fillStyle (`stroke` false) or strokeStyle currently is.
//@wb fn
CanvasStyle_kind :: proc(ctx: CanvasRenderingContext2D, stroke: bool) -> StyleKind

/// The color style as `#rrggbb` or `rgba(...)`.
//@wb fn
CanvasStyle_color :: proc(ctx: CanvasRenderingContext2D, stroke: bool) -> string

/// The script object of a gradient or pattern style: the one it was set from while that is alive, else a new one the
/// caller owns (0 for a color style).
//@wb fn
CanvasStyle_object :: proc(ctx: CanvasRenderingContext2D, stroke: bool) -> u64

/// fillStyle = "color": false (and nothing changes) when it is not a color.
//@wb fn
CanvasStyle_setColor :: proc(ctx: CanvasRenderingContext2D, stroke: bool, color: string) -> bool

/// fillStyle = gradient or pattern object.
//@wb fn
CanvasStyle_setObject :: proc(ctx: CanvasRenderingContext2D, stroke: bool, object: u64)

/// createLinearGradient (the arguments are finite: the binding refuses others).
//@wb fn owned
CanvasFillStrokeStyles_createLinearGradient :: proc(ctx: CanvasRenderingContext2D, x0: f64, y0: f64, x1: f64, y1: f64) -> CanvasGradient

/// createRadialGradient: a negative radius raises Index_Size.
//@wb fn raises owned
CanvasFillStrokeStyles_createRadialGradient :: proc(ctx: CanvasRenderingContext2D, x0: f64, y0: f64, r0: f64, x1: f64, y1: f64, r1: f64) -> CanvasGradient

//@wb fn owned
CanvasFillStrokeStyles_createConicGradient :: proc(ctx: CanvasRenderingContext2D, start_angle: f64, x: f64, y: f64) -> CanvasGradient

/// createPattern(image, repetition): `source` is an element handle (img, canvas) or an object handle (ImageBitmap,
/// OffscreenCanvas); repetition "repeat", "repeat-x", "repeat-y", "no-repeat". Not_Found: no pattern (an image that is
/// not available yet); Syntax: bad repetition; Invalid_State: a canvas with no pixels.
//@wb fn raises
Canvas_createPattern :: proc(ctx: CanvasRenderingContext2D, source: u64, repetition: string) -> CanvasPattern

/// addColorStop(offset, color): Index_Size outside 0 to 1, Syntax for a color that does not parse.
//@wb fn raises
CanvasGradient_addColorStop :: proc(gradient: CanvasGradient, offset: f64, color: string)

/// pattern.setTransform(matrix): the six elements a b c d e f as m11 m12 m21 m22 m41 m42.
//@wb fn
CanvasPattern_setTransformMatrix :: proc(pattern: CanvasPattern, m11: f64, m12: f64, m21: f64, m22: f64, m41: f64, m42: f64)

//@wb fn
CanvasShadowStyles_shadowOffsetX :: proc(ctx: CanvasRenderingContext2D) -> f64

//@wb fn
CanvasShadowStyles_set_shadowOffsetX :: proc(ctx: CanvasRenderingContext2D, value: f64)

//@wb fn
CanvasShadowStyles_shadowOffsetY :: proc(ctx: CanvasRenderingContext2D) -> f64

//@wb fn
CanvasShadowStyles_set_shadowOffsetY :: proc(ctx: CanvasRenderingContext2D, value: f64)

//@wb fn
CanvasShadowStyles_shadowBlur :: proc(ctx: CanvasRenderingContext2D) -> f64

/// Negative or non-finite: ignored.
//@wb fn
CanvasShadowStyles_set_shadowBlur :: proc(ctx: CanvasRenderingContext2D, value: f64)

//@wb fn
CanvasShadowStyles_shadowColor :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasShadowStyles_set_shadowColor :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasFilters_filter :: proc(ctx: CanvasRenderingContext2D) -> string

/// "none" or a list of CSS filter functions (blur, brightness, contrast, grayscale, hue-rotate, invert, opacity,
/// saturate, sepia, drop-shadow); anything that does not parse is ignored.
//@wb fn
CanvasFilters_set_filter :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasRect_clearRect :: proc(ctx: CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64)

//@wb fn
CanvasRect_fillRect :: proc(ctx: CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64)

//@wb fn
CanvasRect_strokeRect :: proc(ctx: CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64)

//@wb fn
CanvasDrawPath_beginPath :: proc(ctx: CanvasRenderingContext2D)

/// fill(path?, rule): `path` is a Path2D handle, 0 for the current path; rule "nonzero" or "evenodd".
//@wb fn
CanvasDrawPath_fill :: proc(ctx: CanvasRenderingContext2D, path: u64, rule: string)

//@wb fn
CanvasDrawPath_stroke :: proc(ctx: CanvasRenderingContext2D, path: u64)

//@wb fn
CanvasDrawPath_clip :: proc(ctx: CanvasRenderingContext2D, path: u64, rule: string)

//@wb fn
CanvasDrawPath_isPointInPath :: proc(ctx: CanvasRenderingContext2D, path: u64, x: f64, y: f64, rule: string) -> bool

//@wb fn
CanvasDrawPath_isPointInStroke :: proc(ctx: CanvasRenderingContext2D, path: u64, x: f64, y: f64) -> bool

/// fillText(text, x, y, maxWidth): `has_max` false when maxWidth was not given.
//@wb fn
CanvasText_fillText :: proc(ctx: CanvasRenderingContext2D, text: string, x: f64, y: f64, max_width: f64, has_max: bool)

//@wb fn
CanvasText_strokeText :: proc(ctx: CanvasRenderingContext2D, text: string, x: f64, y: f64, max_width: f64, has_max: bool)

//@wb fn owned
CanvasText_measureText :: proc(ctx: CanvasRenderingContext2D, text: string) -> TextMetrics

//@wb fn
TextMetrics_width :: proc(m: TextMetrics) -> f64

//@wb fn
TextMetrics_actualBoundingBoxLeft :: proc(m: TextMetrics) -> f64

//@wb fn
TextMetrics_actualBoundingBoxRight :: proc(m: TextMetrics) -> f64

//@wb fn
TextMetrics_fontBoundingBoxAscent :: proc(m: TextMetrics) -> f64

//@wb fn
TextMetrics_fontBoundingBoxDescent :: proc(m: TextMetrics) -> f64

//@wb fn
TextMetrics_actualBoundingBoxAscent :: proc(m: TextMetrics) -> f64

//@wb fn
TextMetrics_actualBoundingBoxDescent :: proc(m: TextMetrics) -> f64

//@wb fn
TextMetrics_emHeightAscent :: proc(m: TextMetrics) -> f64

//@wb fn
TextMetrics_emHeightDescent :: proc(m: TextMetrics) -> f64

//@wb fn
TextMetrics_hangingBaseline :: proc(m: TextMetrics) -> f64

//@wb fn
TextMetrics_alphabeticBaseline :: proc(m: TextMetrics) -> f64

//@wb fn
TextMetrics_ideographicBaseline :: proc(m: TextMetrics) -> f64

/// drawImage: `source` is an element handle (img, canvas, video) or an object handle (ImageBitmap, OffscreenCanvas);
/// `form` is the number of arguments after the image, 2 (dx, dy), 4 (dx, dy, dw, dh) or 8 (sx, sy, sw, sh, dx, dy, dw,
/// dh); the unused ones are 0. An image that is not available yet draws nothing; a broken one, or a canvas with no
/// pixels, raises Invalid_State.
//@wb fn raises
CanvasDrawImage_drawImage :: proc(ctx: CanvasRenderingContext2D, source: u64, form: i32, sx: f64, sy: f64, sw: f64, sh: f64, dx: f64, dy: f64, dw: f64, dh: f64)

/// The largest ImageData a script may make or read back, in bytes (canvas.max_image_data_bytes).
//@wb fn
CanvasImageData_maxBytes :: proc() -> u64

/// getImageData's pixels: straight RGBA8 of the w x h block at (x, y) into `data` (w * h * 4 bytes). Security when the
/// canvas is tainted, Index_Size for an empty block (blocks over canvas.max_image_data_bytes never get here: the binding
/// asks CanvasImageData_maxBytes first and throws a RangeError).
//@wb fn raises out=data
CanvasImageData_get :: proc(ctx: CanvasRenderingContext2D, x: i32, y: i32, w: i32, h: i32, data: bytes)

/// putImageData: the dirty rectangle of `data` (data_w x data_h straight RGBA8) at (dx, dy).
//@wb fn
CanvasImageData_put :: proc(ctx: CanvasRenderingContext2D, data: bytes, data_w: i32, data_h: i32, dx: i32, dy: i32, dirty_x: i32, dirty_y: i32, dirty_w: i32, dirty_h: i32)

//@wb fn
CanvasPathDrawingStyles_lineWidth :: proc(ctx: CanvasRenderingContext2D) -> f64

/// Zero, negative or non-finite: ignored.
//@wb fn
CanvasPathDrawingStyles_set_lineWidth :: proc(ctx: CanvasRenderingContext2D, value: f64)

//@wb fn
CanvasPathDrawingStyles_lineCap :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasPathDrawingStyles_set_lineCap :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasPathDrawingStyles_lineJoin :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasPathDrawingStyles_set_lineJoin :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasPathDrawingStyles_miterLimit :: proc(ctx: CanvasRenderingContext2D) -> f64

//@wb fn
CanvasPathDrawingStyles_set_miterLimit :: proc(ctx: CanvasRenderingContext2D, value: f64)

//@wb fn
CanvasPathDrawingStyles_lineDashOffset :: proc(ctx: CanvasRenderingContext2D) -> f64

//@wb fn
CanvasPathDrawingStyles_set_lineDashOffset :: proc(ctx: CanvasRenderingContext2D, value: f64)

/// setLineDash(segments): ignored when an entry is negative or not finite; an odd count is repeated.
//@wb fn
CanvasPathDrawingStyles_setLineDash :: proc(ctx: CanvasRenderingContext2D, segments: []f64)

//@wb fn
CanvasPathDrawingStyles_lineDashCount :: proc(ctx: CanvasRenderingContext2D) -> i32

//@wb fn
CanvasPathDrawingStyles_lineDashAt :: proc(ctx: CanvasRenderingContext2D, index: i32) -> f64

//@wb fn
CanvasTextDrawingStyles_lang :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasTextDrawingStyles_set_lang :: proc(ctx: CanvasRenderingContext2D, value: string)

/// The CSS font shorthand; one that does not parse is ignored. Relative units (em, %) are relative to the canvas
/// element's font size.
//@wb fn
CanvasTextDrawingStyles_font :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasTextDrawingStyles_set_font :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasTextDrawingStyles_textAlign :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasTextDrawingStyles_set_textAlign :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasTextDrawingStyles_textBaseline :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasTextDrawingStyles_set_textBaseline :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasTextDrawingStyles_direction :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasTextDrawingStyles_set_direction :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasTextDrawingStyles_letterSpacing :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasTextDrawingStyles_set_letterSpacing :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasTextDrawingStyles_wordSpacing :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasTextDrawingStyles_set_wordSpacing :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasTextDrawingStyles_fontKerning :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasTextDrawingStyles_set_fontKerning :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasTextDrawingStyles_fontStretch :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasTextDrawingStyles_set_fontStretch :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasTextDrawingStyles_fontVariantCaps :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasTextDrawingStyles_set_fontVariantCaps :: proc(ctx: CanvasRenderingContext2D, value: string)

//@wb fn
CanvasTextDrawingStyles_textRendering :: proc(ctx: CanvasRenderingContext2D) -> string

//@wb fn
CanvasTextDrawingStyles_set_textRendering :: proc(ctx: CanvasRenderingContext2D, value: string)

/// /////////////////////////////
//@wb fn
CanvasPath_closePath :: proc(p: CanvasPathTarget)

//@wb fn
CanvasPath_moveTo :: proc(p: CanvasPathTarget, x: f64, y: f64)

//@wb fn
CanvasPath_lineTo :: proc(p: CanvasPathTarget, x: f64, y: f64)

//@wb fn
CanvasPath_quadraticCurveTo :: proc(p: CanvasPathTarget, cpx: f64, cpy: f64, x: f64, y: f64)

//@wb fn
CanvasPath_bezierCurveTo :: proc(p: CanvasPathTarget, cp1x: f64, cp1y: f64, cp2x: f64, cp2y: f64, x: f64, y: f64)

/// A negative radius raises Index_Size.
//@wb fn raises
CanvasPath_arcTo :: proc(p: CanvasPathTarget, x1: f64, y1: f64, x2: f64, y2: f64, radius: f64)

//@wb fn
CanvasPath_rect :: proc(p: CanvasPathTarget, x: f64, y: f64, w: f64, h: f64)

/// roundRect: `radii` are the 8 numbers of the four corners (upper-left, upper-right, lower-right, lower-left), x
/// then y radius each. A negative radius raises Range.
//@wb fn raises
CanvasPath_roundRect :: proc(p: CanvasPathTarget, x: f64, y: f64, w: f64, h: f64, radii: []f64)

//@wb fn raises
CanvasPath_arc :: proc(p: CanvasPathTarget, x: f64, y: f64, radius: f64, start_angle: f64, end_angle: f64, counterclockwise: bool = false)

//@wb fn raises
CanvasPath_ellipse :: proc(p: CanvasPathTarget, x: f64, y: f64, radius_x: f64, radius_y: f64, rotation: f64, start_angle: f64, end_angle: f64, counterclockwise: bool = false)

/// new Path2D(): empty; `from` a Path2D handle to copy (0 for none); `svg` path data (M, L, H, V, C, S, Q, T, A, Z and
/// their relative forms) appended when not empty (an invalid string leaves what parsed before the error).
//@wb fn
Path2D_create :: proc(from: u64, svg: string) -> Path2D

/// addPath(path, matrix).
//@wb fn
Path2D_addPath :: proc(target: Path2D, path: Path2D, m11: f64, m12: f64, m21: f64, m22: f64, m41: f64, m42: f64)

/// /////////////////////////////
/// new OffscreenCanvas(width, height): Quota over the limits.
//@wb fn raises
OffscreenCanvas_create :: proc(width: u64, height: u64) -> OffscreenCanvas

//@wb fn
OffscreenCanvas_width :: proc(canvas: OffscreenCanvas) -> u64

//@wb fn
OffscreenCanvas_height :: proc(canvas: OffscreenCanvas) -> u64

/// Sets the size: the canvas is cleared and its context reset. Quota over the limits.
//@wb fn raises
OffscreenCanvas_set_width :: proc(canvas: OffscreenCanvas, value: u64)

//@wb fn raises
OffscreenCanvas_set_height :: proc(canvas: OffscreenCanvas, value: u64)

//@wb fn raises
OffscreenCanvas_context2d :: proc(canvas: OffscreenCanvas, alpha: bool, will_read_frequently: bool) -> CanvasRenderingContext2D

/// transferToImageBitmap(): the pixels move to a new ImageBitmap and the canvas is cleared.
//@wb fn raises owned
OffscreenCanvas_transferToImageBitmap :: proc(canvas: OffscreenCanvas) -> ImageBitmap

//@wb fn
ImageBitmap_width :: proc(bitmap: ImageBitmap) -> u32

//@wb fn
ImageBitmap_height :: proc(bitmap: ImageBitmap) -> u32

/// bitmap.close(): the pixels are freed; the bitmap is 0 x 0 from then on.
//@wb fn
ImageBitmap_close :: proc(bitmap: ImageBitmap)

/// createImageBitmap(image, sx, sy, sw, sh, options): `source` as for drawImage, `form` 0 (whole image) or 4 (a
/// rectangle). The bitmap is a copy of the pixels now, with the full ImageBitmapOptions applied natively: `orient`
/// (0 from-image, 1 flipY), `premul` (0 default, 1 premultiply, 2 none — the result stored premultiplied either way;
/// `none` only affects a source whose alpha is not premultiplied, which never happens for our premultiplied bitmaps,
/// so it is a no-op here and kept for completeness), `colorspace` (0 default, 1 none — we keep the source sRGB bytes
/// so both behave the same), `resize_w` / `resize_h` the wanted output size (0 means keep that axis) and `resize_q`
/// (0 pixelated, 1 low, 2 medium, 3 high). Not_Found: no pixels yet (the image is not available); Invalid_State:
/// broken or empty image; Index_Size: an empty rectangle or an out-of-range resize.
//@wb fn raises
Canvas_createBitmap :: proc(source: u64, form: i32, sx: f64, sy: f64, sw: f64, sh: f64, orient: i32, premul: i32, colorspace: i32, resize_w: i32, resize_h: i32, resize_q: i32) -> ImageBitmap

/// An ImageBitmap of straight RGBA8 pixels (an ImageData, a decoded Blob, a VideoFrame read back). `orient`, `premul`,
/// `colorspace`, `resize_*` and `resize_q` as Canvas_createBitmap.
//@wb fn raises
Canvas_bitmapFromPixels :: proc(data: bytes, width: i32, height: i32, orient: i32, premul: i32, colorspace: i32, resize_w: i32, resize_h: i32, resize_q: i32) -> ImageBitmap

/// /////////////////////////////
/// getContext("bitmaprenderer", {alpha}) on a <canvas> element / an OffscreenCanvas: 0 when a 2D context already
/// holds the canvas (the kinds cannot be mixed).
//@wb fn raises
HTMLCanvasElement_bitmapRenderer :: proc(canvas: HTMLCanvasElement, alpha: bool) -> ImageBitmapRenderingContext

//@wb fn raises
OffscreenCanvas_bitmapRenderer :: proc(canvas: OffscreenCanvas, alpha: bool) -> ImageBitmapRenderingContext

/// context.canvas: the owning <canvas> node or OffscreenCanvas object (0 when the canvas is gone).
//@wb fn
ImageBitmapRenderingContext_canvas :: proc(ctx: ImageBitmapRenderingContext) -> u64

/// transferFromImageBitmap(bitmap): display the bitmap (its pixels move into the canvas and it is detached);
/// `has_bitmap` false is the null argument (clear the canvas). Type when the argument is not an ImageBitmap.
//@wb fn raises
ImageBitmapRenderingContext_transferFromImageBitmap :: proc(ctx: ImageBitmapRenderingContext, bitmap: u64, has_bitmap: bool)

