#+build !windows
#+build !linux
package media

// Systems that are not Windows and not Linux (macOS): no VA-API (that is Linux DRM). H.264 falls to openh264, and a
// VideoToolbox backend would go in its own file later.

vaapi_available :: proc() -> bool { return false }

@(private)
vaapi_h264_create :: proc(track: Track) -> ^Video_Decoder { return nil }
