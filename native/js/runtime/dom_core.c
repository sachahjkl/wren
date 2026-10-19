/* dom_core.c: members of the DOM's core interfaces whose IDL signature the generated glue cannot convert (unions,
 * dictionaries, variadic node lists). */
#include <string.h>
#include "wj.h"
#include "bindings.h"
#include "qjs_internal.h"

/* document.createElement(localName, options): options (a string or {is}) are accepted and ignored (no custom elements) */
JSValue wjr_Document_createElement(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    if (!wj_this(ctx, this_val, WJ_IFACE_Document)) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "Document.createElement", 1, argc); }
    wj_str name;
    if (!wj_to_str(ctx, argv[0], &name, 0, "")) { return JS_EXCEPTION; }
    uint64_t h = 0;
    int32_t st = wr_Document_createElement((const uint8_t *)name.ptr, (uint32_t)name.len, &h);
    wj_str_free(ctx, &name);
    if (st < 0) {
        if (st == wr_Error_Invalid_Argument) { return wj_throw_dom(ctx, "InvalidCharacterError", "The tag name provided is not a valid name."); }
        return wj_throw_status(ctx, st, "Document.createElement");
    }
    return wj_wrap_node(ctx, h);
}
