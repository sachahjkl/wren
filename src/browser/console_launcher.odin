package browser

// wren.com, the console launcher (src/tools/wrencom), travels inside wren.exe so that the release stays one file. Setup
// writes it beside the installed wren.exe when "Add Wren to PATH" is on and takes it away when it is off or when Wren is
// uninstalled (package desktop, launcher.odin: it is part of the PATH option, never written anywhere else). build.bat builds
// it before the browser; the bytes below are that build.
when ODIN_OS == .Windows {
	CONSOLE_LAUNCHER :: #load("../../build/wren.com")
}
