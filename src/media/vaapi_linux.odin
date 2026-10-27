#+build linux
package media

// VA-API: the GPU's video decoder on Linux (the counterpart of DXVA on Windows), reached by dlopen of libva and
// libva-drm so that a machine without them still runs (the decoder then falls back to openh264). This file probes what
// the GPU offers (so h264_supported can say "hardware") and holds the dynamic bindings. The slice-level decode of
// H.264 (picture / slice parameter buffers, reference picture management from the parsed SPS/PPS and slice headers) is
// the large part and is driven by vaapi_h264.odin when present; until then vaapi_h264_create returns nil and Auto uses
// openh264. VA-API is Linux-only (DRM); macOS uses VideoToolbox, not this file.

import "core:sync"
import "core:sys/posix"

@(private)
VADisplay :: distinct rawptr
@(private)
VAStatus :: distinct i32
@(private)
VAProfile :: distinct i32
@(private)
VAEntrypoint :: distinct i32

VA_STATUS_SUCCESS :: VAStatus(0)
VAProfileH264Main :: VAProfile(6)
VAProfileH264High :: VAProfile(7)
VAProfileH264ConstrainedBaseline :: VAProfile(13)
VAEntrypointVLD :: VAEntrypoint(1)

@(private)
Vaapi_Lib :: struct {
	va:      posix.Symbol_Table,
	va_drm:  posix.Symbol_Table,
	drm_fd:  posix.FD,
	// libva-drm
	GetDisplayDRM:    proc "c" (fd: i32) -> VADisplay,
	// libva
	Initialize:       proc "c" (dpy: VADisplay, major, minor: ^i32) -> VAStatus,
	Terminate:        proc "c" (dpy: VADisplay) -> VAStatus,
	MaxNumProfiles:   proc "c" (dpy: VADisplay) -> i32,
	MaxNumEntrypoints: proc "c" (dpy: VADisplay) -> i32,
	QueryConfigProfiles: proc "c" (dpy: VADisplay, profiles: [^]VAProfile, num: ^i32) -> VAStatus,
	QueryConfigEntrypoints: proc "c" (dpy: VADisplay, profile: VAProfile, entrypoints: [^]VAEntrypoint, num: ^i32) -> VAStatus,
}

@(private)
vaapi_lib: Vaapi_Lib
@(private)
vaapi_once: sync.Once
@(private)
vaapi_h264: bool       // the GPU decodes H.264 (a profile with the VLD entrypoint was found)

@(private)
vaapi_sym :: proc(table: posix.Symbol_Table, name: cstring) -> rawptr { return posix.dlsym(table, name) }

@(private)
vaapi_dlopen :: proc(name: cstring) -> posix.Symbol_Table {
	return posix.dlopen(name, posix.RTLD_LOCAL + {.NOW})
}

@(private)
vaapi_load :: proc() {
	va := vaapi_dlopen("libva.so.2")
	if va == nil { va = vaapi_dlopen("libva.so.1") }
	if va == nil { va = vaapi_dlopen("libva.so") }
	drm := vaapi_dlopen("libva-drm.so.2")
	if drm == nil { drm = vaapi_dlopen("libva-drm.so.1") }
	if drm == nil { drm = vaapi_dlopen("libva-drm.so") }
	if va == nil || drm == nil {
		if va != nil { posix.dlclose(va) }
		if drm != nil { posix.dlclose(drm) }
		return
	}
	l := &vaapi_lib
	l.va, l.va_drm = va, drm
	l.GetDisplayDRM = auto_cast vaapi_sym(drm, "vaGetDisplayDRM")
	l.Initialize = auto_cast vaapi_sym(va, "vaInitialize")
	l.Terminate = auto_cast vaapi_sym(va, "vaTerminate")
	l.QueryConfigProfiles = auto_cast vaapi_sym(va, "vaQueryConfigProfiles")
	l.QueryConfigEntrypoints = auto_cast vaapi_sym(va, "vaQueryConfigEntrypoints")
	l.MaxNumProfiles = auto_cast vaapi_sym(va, "vaMaxNumProfiles")
	l.MaxNumEntrypoints = auto_cast vaapi_sym(va, "vaMaxNumEntrypoints")
	if l.GetDisplayDRM == nil || l.Initialize == nil || l.Terminate == nil || l.QueryConfigProfiles == nil || l.QueryConfigEntrypoints == nil {
		return
	}
	// The render node: no window system, any user with video access (the group `render`).
	fd := posix.open("/dev/dri/renderD128", {.RDWR})
	if fd < posix.FD(0) { fd = posix.open("/dev/dri/card0", {.RDWR}) }
	if fd < posix.FD(0) { return }
	l.drm_fd = fd
	dpy := l.GetDisplayDRM(i32(fd))
	if dpy == nil { posix.close(fd); l.drm_fd = posix.FD(-1); return }
	major, minor: i32
	if l.Initialize(dpy, &major, &minor) != VA_STATUS_SUCCESS {
		posix.close(fd); l.drm_fd = posix.FD(-1)
		return
	}
	// Probe only: tear the display and the device down afterwards. A real decoder will keep its own display open.
	vaapi_h264 = vaapi_probe_h264(dpy)
	l.Terminate(dpy)
	posix.close(fd)
	l.drm_fd = posix.FD(-1)
}

@(private)
vaapi_probe_h264 :: proc(dpy: VADisplay) -> bool {
	l := &vaapi_lib
	max_p := int(l.MaxNumProfiles(dpy))
	if max_p <= 0 || max_p > 256 { return false }
	profiles := make([]VAProfile, max_p, context.temp_allocator)
	np: i32
	if l.QueryConfigProfiles(dpy, raw_data(profiles), &np) != VA_STATUS_SUCCESS { return false }
	max_e := int(l.MaxNumEntrypoints(dpy))
	if max_e <= 0 || max_e > 256 { return false }
	eps := make([]VAEntrypoint, max_e, context.temp_allocator)
	for i in 0 ..< int(np) {
		p := profiles[i]
		if p != VAProfileH264Main && p != VAProfileH264High && p != VAProfileH264ConstrainedBaseline { continue }
		ne: i32
		if l.QueryConfigEntrypoints(dpy, p, raw_data(eps), &ne) != VA_STATUS_SUCCESS { continue }
		for j in 0 ..< int(ne) {
			if eps[j] == VAEntrypointVLD { return true }
		}
	}
	return false
}

vaapi_available :: proc() -> bool {
	sync.once_do(&vaapi_once, vaapi_load)
	return vaapi_h264
}

// The GPU decode path is not written yet: slice-level H.264 (picture and slice parameter buffers from the parsed
// SPS / PPS and slice headers, DPB management, surface mapping to I420) is the large piece. Until it is, VA-API only
// advertises availability; h264_create falls back to openh264 (Auto) or returns nil (Vaapi only). Returning nil here
// keeps playback correct meanwhile.
@(private)
vaapi_h264_create :: proc(track: Track) -> ^Video_Decoder { return nil }
