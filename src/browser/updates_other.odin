#+build !windows
package browser

// Wren's Linux release is a tar.gz (its program beside its libraries) and its Nix package is updated by Nix: no release
// publishes a program the updater can put in place, so Wren has no updater here (the settings show no Updates line).
UPDATES_SELF :: false

updates_start :: proc(app: ^App) {}
