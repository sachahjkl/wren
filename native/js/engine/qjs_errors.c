/* errors.c: the exceptions bindings throw (Web IDL "simple exceptions" and DOMException) and the mapping from the
 * browser's Error codes (api/web.widl) to them. */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "wj.h"

wj_val wj_throw_type(wj_ctx *ctx, const char *fmt, ...)
{
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    return JS_ThrowTypeError(ctx, "%s", msg);
}

wj_val wj_throw_range(wj_ctx *ctx, const char *fmt, ...)
{
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    return JS_ThrowRangeError(ctx, "%s", msg);
}

/* DOMException's legacy codes (Web IDL "DOMException names table") */
static const struct { const char *name; int code; } wj_dom_codes[] = {
    {"IndexSizeError", 1}, {"HierarchyRequestError", 3}, {"WrongDocumentError", 4}, {"InvalidCharacterError", 5},
    {"NoModificationAllowedError", 7}, {"NotFoundError", 8}, {"NotSupportedError", 9}, {"InUseAttributeError", 10},
    {"InvalidStateError", 11}, {"SyntaxError", 12}, {"InvalidModificationError", 13}, {"NamespaceError", 14},
    {"InvalidAccessError", 15}, {"TypeMismatchError", 17}, {"SecurityError", 18}, {"NetworkError", 19},
    {"AbortError", 20}, {"URLMismatchError", 21}, {"QuotaExceededError", 22}, {"TimeoutError", 23},
    {"InvalidNodeTypeError", 24}, {"DataCloneError", 25},
};

int wj_dom_exception_code(const char *name)
{
    for (size_t i = 0; i < sizeof wj_dom_codes / sizeof wj_dom_codes[0]; i++) {
        if (strcmp(wj_dom_codes[i].name, name) == 0) { return wj_dom_codes[i].code; }
    }
    return 0;
}

/* runtime/domexception.c makes real DOMException objects; without it (bindings not generated yet) an Error with the
 * right name stands in. */
__attribute__((weak)) wj_val wj_new_dom_exception(wj_ctx *ctx, const char *name, const char *message)
{
    JSValue e = JS_NewError(ctx);
    JS_DefinePropertyValueStr(ctx, e, "name", JS_NewString(ctx, name), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    JS_DefinePropertyValueStr(ctx, e, "message", JS_NewString(ctx, message), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    JS_DefinePropertyValueStr(ctx, e, "code", JS_NewInt32(ctx, wj_dom_exception_code(name)), JS_PROP_CONFIGURABLE);
    return e;
}

wj_val wj_throw_dom(wj_ctx *ctx, const char *name, const char *message)
{
    JSValue e = wj_new_dom_exception(ctx, name, message ? message : "");
    if (JS_IsException(e)) { return e; }
    return JS_Throw(ctx, e);
}

wj_val wj_throw_unsupported(wj_ctx *ctx, const char *iface, const char *member)
{
    char msg[256];
    snprintf(msg, sizeof msg, "%s.%s is not supported by this browser", iface, member);
    return wj_throw_dom(ctx, "NotSupportedError", msg);
}

/* the message the browser recorded with the error (web.Exception_message) */
static const char *wj_last_message(char *buf, size_t cap)
{
    int32_t n = wr_Exception_message((uint8_t *)buf, (uint32_t)(cap - 1));
    if (n < 0) { n = 0; }
    if ((size_t)n > cap - 1) { n = (int32_t)(cap - 1); }
    buf[n] = 0;
    return buf;
}

wj_val wj_throw_status(wj_ctx *ctx, int32_t status, const char *what)
{
    char msg[600];
    wj_last_message(msg, sizeof msg);
    if (!msg[0] && what) { snprintf(msg, sizeof msg, "%s failed", what); }
    switch (status) {
    case wr_Error_Invalid_Handle: return JS_ThrowTypeError(ctx, "%s", msg[0] ? msg : "the object is no longer alive");
    case wr_Error_Hierarchy: return wj_throw_dom(ctx, "HierarchyRequestError", msg);
    case wr_Error_Not_Found: return wj_throw_dom(ctx, "NotFoundError", msg);
    case wr_Error_Invalid_Argument: return wj_throw_dom(ctx, "InvalidStateError", msg);
    case wr_Error_Attached: return wj_throw_dom(ctx, "InvalidStateError", msg);
    case wr_Error_Type: return JS_ThrowTypeError(ctx, "%s", msg);
    case wr_Error_Range: return JS_ThrowRangeError(ctx, "%s", msg);
    case wr_Error_Security: return wj_throw_dom(ctx, "SecurityError", msg);
    case wr_Error_Quota: return wj_throw_dom(ctx, "QuotaExceededError", msg);
    case wr_Error_Not_Supported: return wj_throw_dom(ctx, "NotSupportedError", msg);
    case wr_Error_Syntax: return wj_throw_dom(ctx, "SyntaxError", msg);
    case wr_Error_Abort: return wj_throw_dom(ctx, "AbortError", msg);
    case wr_Error_Timeout: return wj_throw_dom(ctx, "TimeoutError", msg);
    case wr_Error_Invalid_State: return wj_throw_dom(ctx, "InvalidStateError", msg);
    case wr_Error_Data_Clone: return wj_throw_dom(ctx, "DataCloneError", msg);
    case wr_Error_Network: return wj_throw_dom(ctx, "NetworkError", msg);
    case wr_Error_Encoding: return wj_throw_dom(ctx, "EncodingError", msg);
    case wr_Error_Index_Size: return wj_throw_dom(ctx, "IndexSizeError", msg);
    case wr_Error_Not_Allowed: return wj_throw_dom(ctx, "NotAllowedError", msg);
    case wr_Error_Invalid_Access: return wj_throw_dom(ctx, "InvalidAccessError", msg);
    case wr_Error_Invalid_Character: return wj_throw_dom(ctx, "InvalidCharacterError", msg);
    case wr_Error_Namespace: return wj_throw_dom(ctx, "NamespaceError", msg);
    case wr_Error_In_Use_Attribute: return wj_throw_dom(ctx, "InUseAttributeError", msg);
    case wr_Error_Wrong_Document: return wj_throw_dom(ctx, "WrongDocumentError", msg);
    case wr_Error_Invalid_Node_Type: return wj_throw_dom(ctx, "InvalidNodeTypeError", msg);
    case wr_Error_Invalid_Modification: return wj_throw_dom(ctx, "InvalidModificationError", msg);
    case wr_Error_No_Modification_Allowed: return wj_throw_dom(ctx, "NoModificationAllowedError", msg);
    default: return JS_ThrowInternalError(ctx, "%s (error %d)", msg, (int)status);
    }
}
