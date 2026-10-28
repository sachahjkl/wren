#+build !windows
package browser

// The mouse's back / forward buttons and the browser media keys reach the shell through a native-window subclass on
// Windows (app_commands_windows.odin). The toolkit's Linux window surfaces only Left / Right / Middle mouse buttons and
// no media keys, so there is nothing to hook here yet: these honest no-ops keep main.odin's init / destroy calls valid
// until the platform layer reports extra buttons and app-command keys. Keyboard Alt+Left / Alt+Right still go back and
// forward (the shell's own key handling), as on every system.

app_commands_init :: proc(app: ^App) {}
app_commands_destroy :: proc() {}
