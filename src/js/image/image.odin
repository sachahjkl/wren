// Package js_image: the JavaScript engine module, pre-initialized (src\tools\buildjs -> build\js\wren_js.wasm),
// embedded in the executable. Separate from package js so that the tool that makes the image does not need it.
package js_image

// The folder of build\ the image is in (-define:WREN_JS_DIR): js, or js_quick for wrentool build quick (an engine not optimised).
JS_DIR :: #config(WREN_JS_DIR, "js")

IMAGE := #load("../../../build/" + JS_DIR + "/wren_js.wasm")
