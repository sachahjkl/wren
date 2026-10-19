/* Shared between the QuickJS-specific files of native/js/engine. */
#ifndef WJ_QJS_INTERNAL_H
#define WJ_QJS_INTERNAL_H

#include "wj.h"

/* platform classes: every platform object is of one of these, with a wj_obj as opaque */
extern JSClassID wj_class_plain, wj_class_indexed, wj_class_named, wj_class_group;

void wj_report_to_host(wj_ctx *ctx, wj_val exc);
void wj_report_pending(wj_ctx *ctx);
void wj_console_text(int level, const char *text, size_t len);

/* the wj_obj of any platform object (any platform class), or NULL */
static inline wj_obj *wj_obj_of(JSValueConst v)
{
    if (!JS_IsObject(v)) { return NULL; }
    JSClassID id = JS_GetClassID(v);
    if (id != wj_class_plain && id != wj_class_indexed && id != wj_class_named) { return NULL; }
    return (wj_obj *)JS_GetOpaque(v, id);
}

#endif
