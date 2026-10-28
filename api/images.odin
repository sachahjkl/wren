// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=images order=23 exposed=(Window,Worker)
/// Images: HTMLImageElement (<img> and <input type=image>) and decoding image files from buffers. naturalWidth and
/// naturalHeight are density-corrected CSS pixels (0 until the image is available).
package api_images

//@wb handle parent=Element host=Img_Element lookup=lookup_HTMLImageElement
HTMLImageElement :: distinct Handle

//@wb fn
HTMLImageElement_naturalWidth :: proc(image: HTMLImageElement) -> i32

//@wb fn
HTMLImageElement_naturalHeight :: proc(image: HTMLImageElement) -> i32

//@wb fn
HTMLImageElement_complete :: proc(image: HTMLImageElement) -> bool

/// The absolute URL of the chosen source ("" when none).
//@wb fn
HTMLImageElement_currentSrc :: proc(image: HTMLImageElement) -> string

/// image.decode(): settles (value 0) once decoded at its natural size; rejected with Encoding when it is broken or its
/// source changes first.
//@wb fn
HTMLImageElement_decode :: proc(image: HTMLImageElement) -> Promise

/// Decodes an image file (PNG, JPEG, GIF, BMP, ICO, TIFF, WebP / AVIF where the codecs exist) on the decoding
/// threads: settles with a buffer of RGBA8 pixels (straight alpha, sRGB, rows top-down) as value and "<width>x<height>"
/// as text (first frame of an animation). Rejected with Encoding (not an image, corrupt, over the limits) or Quota.
//@wb fn
Image_decode :: proc(data: Buffer) -> Promise(Buffer)

