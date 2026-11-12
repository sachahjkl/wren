#+build !linux
package browser

// Windows ends a program with a message of its own (WM_CLOSE, WM_ENDSESSION), which the window already handles.

end_signal_install :: proc(app: ^App) {}

end_signal_check :: proc(app: ^App) {}
