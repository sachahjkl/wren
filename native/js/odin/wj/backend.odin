// backend.odin: which engine the layer sits on.
//
//   (default)            QuickJS-ng in C: quickjs.h's real symbols are `foreign` (quickjs.odin, m*_quickjs.odin).
//   -define:WJ_JSRT=true the Odin runtime (src/engine/jsrt) through the QuickJS C API of src/engine/jscapi:
//                        the same names are aliases of jscapi's procedures (backend_jsrt.odin), the `foreign`
//                        blocks are not compiled, and nothing else in the glue changes.
//
// Domain files never see the difference: they call wj.JS_Call, wj.JS_NewObject ... either way.
package wj

WJ_JSRT :: true   // the only engine now: the Odin runtime (the QuickJS-ng C engine this layer once sat on is gone)
