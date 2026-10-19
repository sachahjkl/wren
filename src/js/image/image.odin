// Package js_image: the JavaScript engine module, pre-initialized (tools\build_js.ps1 -> build\js\wren_js.wasm),
// embedded in the executable. Separate from package js so that the tool that makes the image does not need it.
package js_image

IMAGE := #load("../../../build/js/wren_js.wasm")
