package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "toolkit:platform"
import wren_desktop "wb:desktop"

// The profile's folder under the configuration folder, the vendor's then Wren's (src/md/features/profile.md).
APP_FOLDER :: wren_desktop.VENDOR_KEY + platform.USER_DIR_SEPARATOR + APP_NAME
// Its name up to 0.8.0, which the first start after moves.
@(private = "file") OLD_APP_FOLDER :: APP_NAME

// The profile of a Wren without --profile and without a portable copy. The browser and `wren ctl` both take it from
// here: the remote channel's name comes from this path. "build/profile" when the system names no configuration folder.
default_profile_dir :: proc(allocator := context.allocator) -> string {
	dir := platform.user_dir(.Config, APP_FOLDER, allocator)
	return dir != "" ? dir : strings.clone("build/profile", allocator)
}

// Moves <config>/Wren to <config>/FromentSoftware/Wren once, before anything reads the profile. If the move fails, the
// old folder stays the profile for this run, so the person never meets an empty browser; `why` says what failed.
profile_folder_move :: proc(allocator := context.allocator) -> (dir: string, why: string) {
	_, why = platform.user_dirs_move(OLD_APP_FOLDER, APP_FOLDER, {.Config})
	if why != "" {
		old := platform.user_dir(.Config, OLD_APP_FOLDER, context.temp_allocator)
		if old != "" && os.is_dir(old) { return strings.clone(old, allocator), fmt.aprintf("%s; the profile stays in %s", why, old, allocator = allocator) }
	}
	return default_profile_dir(allocator), strings.clone(why, allocator)
}
