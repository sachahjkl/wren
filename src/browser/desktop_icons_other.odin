#+build !windows
package browser

// The icons of the theme on freedesktop.org desktops (desktop_icons_windows.odin: none, Windows uses the executable's
// own): every size the logo is drawn at (assets/icons/<size>.png, wrentool logo), so that a desktop that asks for one at
// a scale (28 px at 125 %: 35) takes the nearest drawn one, not a smaller one stretched.

import "core:strconv"
import "core:strings"
import "core:sync"
import desktop "toolkit:desktop"

when IS_DEV_BUILD {
	@(private = "file") DESKTOP_ICON_FILES := #load_directory("../../assets/dev/icons")
} else {
	@(private = "file") DESKTOP_ICON_FILES := #load_directory("../../assets/icons")
}
@(private = "file") desktop_icon_list: [32]desktop.Icon   // (more than the sizes drawn)
@(private = "file") desktop_icon_count: int
@(private = "file") desktop_icon_once: sync.Once

// Made once, kept for the process: the Setup dialog's thread reads them after the frame that asked.
desktop_icons :: proc() -> []desktop.Icon {
	sync.once_do(&desktop_icon_once, proc() {
		for f in DESKTOP_ICON_FILES {
			if desktop_icon_count == len(desktop_icon_list) { break }
			if size, ok := strconv.parse_int(strings.trim_suffix(f.name, ".png")); ok {
				desktop_icon_list[desktop_icon_count] = desktop.Icon{size, f.data}
				desktop_icon_count += 1
			}
		}
	})
	return desktop_icon_list[:desktop_icon_count]
}
