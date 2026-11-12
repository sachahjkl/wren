#+build !windows
package browser

// No release is made for this system yet: there is nothing to install and no download to name.
update_install_supported :: proc() -> bool { return false }
update_platform :: proc() -> string { return "" }
