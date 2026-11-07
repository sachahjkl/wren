// Package js_code: the machine code of the JavaScript engine's image (jsengine precompile -> build\js\wren_js.code; src\wasm\shipped.odin),
// embedded in the program a user runs, which is one file. The build of wren says WREN_SHIPPED_CODE, and with it a missing
// file is a failed build, not a program that compiles the engine at its users'. So does build\e2e_test.exe: on pages of
// their own, the blocks of a compile take minutes. Other test programs go without (their processes share a disk cache,
// and 22 MB each is a lot for what they do with it).
package js_code

when #config(WREN_SHIPPED_CODE, false) {
	CODE := #load("../../../../build/js/wren_js.code")
} else {
	CODE: []byte
}
