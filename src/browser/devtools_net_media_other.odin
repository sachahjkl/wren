#+build !windows
package browser

// The developer-tools media preview plays MP4 and WebM with the browser's own player on every system. Other formats rely
// on the system's media control interface, which is Windows' MCI (devtools_net_media_windows.odin). There is no portable
// MCI, so off Windows this stub always fails: opening such a media returns false, the preview shows "the system cannot
// play this format" instead of playing it, and the `.System` mode never activates. A fuller Linux preview (GStreamer or
// the media package growing these demuxers) is a later chantier.

@(private)
mci :: proc(cmd: string) -> (result: string, ok: bool) { return "", false }
