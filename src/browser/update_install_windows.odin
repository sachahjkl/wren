package browser

import update "toolkit:update"

// The installer replaces the executable in place: Windows only for now.
update_install_supported :: proc() -> bool { return true }

// The name of this system in the manifest's downloads.
update_platform :: proc() -> string { return update.PLATFORM }
