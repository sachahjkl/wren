/* wj.h: the engine-agnostic layer of Wren's JavaScript realm.
 *
 * Everything above this header (the bindings generated from the Web IDL of the specifications, native/js/gen, and the
 * hand-written members, native/js/runtime) is written against it; everything below it (native/js/engine/qjs_*.c) is
 * the only code that knows the engine is QuickJS-ng. Moving to another engine (SpiderMonkey compiled to Wasm) means
 * reimplementing this header, not the bindings.
 *
 * Model:
 *   * A realm is one instance of this module: one engine runtime, one context, one global object. The browser creates
 *     it from the pre-initialized image (wj_preinit ran at build time), then calls wj_realm_start.
 *   * A platform object (a DOM node, an Event, a URL...) is a JS object of one of the engine's platform classes whose
 *     private data is a wj_obj: the interface it implements (an index into wj_interfaces, numbered in pre-order of the
 *     inheritance tree so that "is an X" is a range check) and the browser's handle of the object behind it.
 *   * A node or host object has at most one wrapper: wj_wrap returns the same JS object for the same handle as long as
 *     it is alive (wrapper cache). The wrappers of one DOM tree keep each other alive (wj_gc_prologue), so a detached
 *     tree survives exactly as long as JavaScript can reach any node of it; a dead wrapper unpins its node.
 *   * Conversions follow Web IDL (ECMAScript binding): wj_to_* take a value and an out parameter and return false with
 *     an exception pending when the conversion throws.
 */
#ifndef WJ_H
#define WJ_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(WJ_ENGINE_SPIDERMONKEY)
#  error "SpiderMonkey backend not written yet"
#else
#  include "qjs_backend.h"   /* wj_ctx, wj_val, wj_native, wj_getter, wj_setter and the inline value helpers */
#endif

#define WJ_EXPORT(name) __attribute__((export_name(name), visibility("default")))
#define WJ_UNUSED(x) (void)(x)
#define WJ_LIKELY(x) __builtin_expect(!!(x), 1)
#define WJ_UNLIKELY(x) __builtin_expect(!!(x), 0)

/* ---- interfaces (tables generated from the Web IDL, gen/bindings.c) ---- */

enum {
    WJ_M_METHOD = 1,          /* operation on the prototype (or the instance when unforgeable) */
    WJ_M_ATTRIBUTE,           /* accessor on the prototype (or the instance when unforgeable) */
    WJ_M_CONSTANT,            /* on the interface object and the prototype */
    WJ_M_STATIC_METHOD,       /* on the interface object */
    WJ_M_STATIC_ATTRIBUTE,
};

enum {
    WJ_F_UNFORGEABLE   = 1 << 0,   /* [LegacyUnforgeable]: own, non-configurable property of each instance */
    WJ_F_REPLACEABLE   = 1 << 1,   /* [Replaceable]: setting it defines an own data property */
    WJ_F_SAME_OBJECT   = 1 << 2,   /* [SameObject]: the getter's first result is kept (slot in `length`) */
    WJ_F_LENIENT_THIS  = 1 << 3,   /* [LegacyLenientThis]: a wrong `this` gives undefined, no exception */
    WJ_F_NOT_ENUMERABLE = 1 << 4,
    WJ_F_SECURE        = 1 << 5,   /* [SecureContext]: absent from realms that are not secure contexts */
    WJ_F_NOT_WINDOW    = 1 << 6,   /* absent from this kind of realm although its interface is there */
    WJ_F_NOT_DEDICATED = 1 << 7,
    WJ_F_SETTER_UNSUPPORTED = 1 << 8,   /* writable in the IDL, setting it is not implemented: throws */
    WJ_F_NOT_SHARED    = 1 << 9,
    WJ_F_NOT_SERVICE   = 1 << 10,
};

/* What an interface is exposed to ([Exposed]), and the kind of a realm's global (wj_realm.scope). WJ_EXPOSE_WORKER is
 * a dedicated worker's; wj_realm.kind stays WINDOW or WORKER for code that only asks "a document or a worker?". */
enum {
    WJ_EXPOSE_WINDOW = 1 << 0,
    WJ_EXPOSE_WORKER = 1 << 1,
    WJ_EXPOSE_SHARED_WORKER = 1 << 2,
    WJ_EXPOSE_SERVICE_WORKER = 1 << 3,
};
#define WJ_EXPOSE_ANY_WORKER (WJ_EXPOSE_WORKER | WJ_EXPOSE_SHARED_WORKER | WJ_EXPOSE_SERVICE_WORKER)

enum {
    WJ_I_GLOBAL              = 1 << 0,   /* [Global]: the realm's global object implements it */
    WJ_I_NO_INTERFACE_OBJECT = 1 << 1,   /* mixin-like: no constructor property on the global */
    WJ_I_NAMESPACE           = 1 << 2,   /* a Web IDL namespace (console, CSS): a plain object */
    WJ_I_CALLBACK            = 1 << 3,   /* callback interface with constants (NodeFilter): an object, no prototype */
    WJ_I_UNSUPPORTED         = 1 << 4,   /* nothing of it is implemented: exposed only with javascript.bindings.expose_unimplemented */
    WJ_I_OVERRIDE_BUILTINS   = 1 << 5,   /* (named) [LegacyOverrideBuiltIns]: named properties shadow the prototype */
    WJ_I_HAS_UNFORGEABLE     = 1 << 6,   /* has [LegacyUnforgeable] members: defined on each instance */
    WJ_I_SECURE              = 1 << 7,   /* [SecureContext] */
    WJ_I_ARRAY_ITERATOR      = 1 << 8,   /* value iterator of an indexed collection: Array.prototype's iterators */
    WJ_I_CTOR_UNSUPPORTED    = 1 << 9,   /* has a constructor the browser does not implement (NotSupportedError) */
    WJ_I_INDEXED_ITERATOR    = 1 << 10,  /* indexed getter and length, no iterable declaration: @@iterator is Array's values (Web IDL §3.7.6) */
    WJ_I_UNENUMERABLE_NAMED  = 1 << 11,  /* [LegacyUnenumerableNamedProperties]: named properties are not enumerable */
};

/* How instances of an interface answer property lookups beyond their prototype (Web IDL "legacy platform objects"). */
enum {
    WJ_CLASS_PLAIN = 0,
    WJ_CLASS_INDEXED,         /* indexed getter (NodeList, HTMLCollection, DOMTokenList...) */
    WJ_CLASS_NAMED,           /* named getter/setter/deleter on a map (DOMStringMap, Storage) */
};

typedef struct wj_member {
    const char *name;
    uint8_t     kind;
    uint16_t    flags;
    uint16_t    length;      /* Function.length of a method; the [SameObject] slot of an attribute */
    wj_native   fn;
    wj_getter   get;
    wj_setter   set;         /* NULL: readonly */
    double      value;       /* constant */
} wj_member;

typedef struct wj_interface {
    const char       *name;
    int16_t           parent;         /* index in wj_interfaces, -1 for none */
    uint16_t          exposed;        /* WJ_EXPOSE_* */
    uint16_t          flags;          /* WJ_I_* */
    uint8_t           class_kind;     /* WJ_CLASS_* */
    uint16_t          ctor_length;
    wj_native         ctor;           /* NULL: "Illegal constructor" */
    const wj_member  *members;
    uint16_t          n_members;
    uint16_t          subtree_end;    /* interfaces [index, subtree_end) inherit from this one (pre-order) */
    /* legacy platform objects (WJ_CLASS_INDEXED / NAMED) */
    wj_val          (*index_get)(wj_ctx *ctx, wj_val obj, uint32_t index, bool *found);
    uint32_t        (*length_get)(wj_ctx *ctx, wj_val obj);
    wj_val          (*named_get)(wj_ctx *ctx, wj_val obj, const char *name, size_t len, bool *found);
    int             (*named_set)(wj_ctx *ctx, wj_val obj, const char *name, size_t len, wj_val value);   /* -1 throws */
    int             (*named_delete)(wj_ctx *ctx, wj_val obj, const char *name, size_t len);            /* 1 deleted */
    int             (*named_keys)(wj_ctx *ctx, wj_val obj, wj_val array);                               /* fills, -1 throws */
    const char       *legacy_alias;   /* [LegacyWindowAlias] (webkitURL...) */
    const char       *factory_name;   /* [LegacyFactoryFunction] (Image, Option, Audio) */
    wj_native         factory;
    uint16_t          factory_length;
} wj_interface;

extern const wj_interface wj_interfaces[];
extern const int wj_interface_count;

/* the interface index of a name (linear scan of the generated table: start-up and cached lookups), -1 when unknown */
int wj_interface_find(const char *name);

/* ---- platform objects ---- */

typedef struct wj_group wj_group;
typedef struct wj_obj wj_obj;

/* An event listener or event handler registered from JavaScript on a platform object: kept by the object's wrapper
 * (so it lives exactly as long as the target is reachable), registered with the browser under `slot`. */
typedef struct wj_listener {
    struct wj_listener *next;
    wj_val       callback;   /* counted: a function or an object with handleEvent; a handler's value (or null) */
    wj_val       type;       /* counted: the event type (a string) */
    int32_t      host_id;    /* the browser's listener id */
    uint32_t     slot;       /* the `user` value the browser calls back with */
    uint8_t      capture, once, passive;
    uint8_t      handler;    /* an event handler (on<type>): 1 plain, 2 OnErrorEventHandler, 3 OnBeforeUnload */
    wj_obj      *owner;
} wj_listener;

struct wj_obj {
    uint64_t       handle;        /* the browser's object (node or host object); 0 for objects only the engine has */
    uint16_t       iface;         /* index in wj_interfaces */
    uint8_t        kind;          /* WJ_KIND_* */
    uint8_t        flags;         /* WJ_OBJ_* */
    uint32_t       group_slot;    /* position in its group's member array */
    wj_group      *group;         /* nodes: the tree whose wrappers live and die together (valid while group_val is) */
    wj_val         group_val;     /* the group object, counted (undefined when none) */
    wj_listener   *listeners;     /* event listeners and handlers registered from JavaScript */
    void          *impl;          /* data of interfaces implemented in the engine (Event state, iterators...) */
    void         (*impl_free)(void *impl);
    /* marks the JS values `impl` holds: call wj_mark(rt, value, mark_func) for each */
    void         (*impl_mark)(void *rt, void *impl, void *mark_func);
    wj_val         self;          /* the wrapper itself (not counted) */
    wj_val        *same;          /* [SameObject] results, by slot (counted; NULL until the first) */
    uint16_t       n_same;
};

enum { WJ_KIND_NONE = 0, WJ_KIND_NODE, WJ_KIND_HOST, WJ_KIND_GLOBAL };
enum {
    WJ_OBJ_OWNED   = 1 << 0,      /* the realm created the host object: released with the wrapper */
};

/* from an impl_mark callback */
void wj_mark(void *rt, wj_val v, void *mark_func);

/* The platform object behind `v` when it implements interface `iface` (or a descendant), else NULL (no exception). */
wj_obj *wj_unwrap(wj_val v, int iface);
/* `this` of an operation or attribute of `iface`: NULL with a TypeError ("Illegal invocation") pending otherwise. The
 * global object stands for itself when `this` is undefined (calls like setTimeout(...) without a receiver). */
wj_obj *wj_this(wj_ctx *ctx, wj_val this_val, int iface);

/* The wrapper of a node handle (created on first use, the most derived interface chosen from the node), or null. */
wj_val wj_wrap_node(wj_ctx *ctx, uint64_t node);
/* The wrapper of a host object of interface `iface` (created on first use), or null for handle 0. */
wj_val wj_wrap_host(wj_ctx *ctx, uint64_t handle, int iface);
/* A new platform object of `iface` with no browser object behind it (implemented in the engine: `impl`). */
wj_val wj_new_object(wj_ctx *ctx, int iface, void *impl, void (*impl_free)(void *));
/* The cached wrapper of a handle, or undefined (no reference taken; does not create one). */
wj_val wj_cached(wj_ctx *ctx, uint64_t handle);

/* ---- realm ---- */

typedef struct wj_realm {
    wj_ctx      *ctx;
    int          kind;            /* WJ_EXPOSE_WINDOW or WJ_EXPOSE_WORKER (any kind of worker) */
    int          scope;           /* one WJ_EXPOSE_* bit: what the global exposes (window, dedicated, shared, service) */
    wj_obj       global_obj;      /* the global object's platform data (Window / WorkerGlobalScope) */
    wj_val       global;
    wj_val      *protos;          /* per interface: prototype object */
    wj_val      *ctors;           /* per interface: interface object (or undefined) */
    bool         started;
    bool         in_gc_prologue;
} wj_realm;

extern wj_realm wj_the_realm;
static inline wj_realm *wj_realm_of(wj_ctx *ctx) { WJ_UNUSED(ctx); return &wj_the_realm; }

/* ---- errors (DOMException, simple exceptions, the browser's Error codes) ---- */

/* The engine's own throwers (the message is formatted into the engine's 256-byte buffer either way). */
#define wj_throw_type JS_ThrowTypeError
#define wj_throw_range JS_ThrowRangeError
/* A DOMException with `name` ("NotFoundError", ...) and a message. */
wj_val wj_throw_dom(wj_ctx *ctx, const char *name, const char *message);
/* The exception for a negative wr_Error a browser function returned, with the message it recorded. */
wj_val wj_throw_status(wj_ctx *ctx, int32_t status, const char *what);
/* member not implemented by the browser */
wj_val wj_throw_unsupported(wj_ctx *ctx, const char *iface, const char *member);

/* ---- strings ---- */

/* A UTF-8 view of a converted string (owned: wj_str_free). */
typedef struct wj_str {
    const char *ptr;
    size_t      len;
    bool        owned;   /* the engine's copy: wj_str_free releases it */
} wj_str;

/* Scratch buffer for string results of browser functions: grows to fit, one per realm (results are converted to JS
 * strings before the next call). */
typedef struct wj_buf {
    uint8_t *data;
    uint32_t cap;
} wj_buf;

extern wj_buf wj_scratch;
/* Calls `fill(buf, cap)` (a browser function returning a full length or a negative Error) until the result fits; the
 * bytes are in wj_scratch.data. Returns the length or the negative Error. */
#define WJ_FETCH_STRING(len_out, call_with_buf_cap)                                                   \
    do {                                                                                              \
        int32_t _n = (call_with_buf_cap);                                                             \
        if (_n > 0 && (uint32_t)_n > wj_scratch.cap) {                                                \
            if (!wj_scratch_grow((uint32_t)_n)) { _n = -13; }                                         \
            else { _n = (call_with_buf_cap); }                                                        \
        }                                                                                             \
        (len_out) = _n;                                                                               \
    } while (0)
bool wj_scratch_grow(uint32_t need);

/* ---- Web IDL conversions (ECMAScript binding). Each returns false with an exception pending when it throws. ---- */

static inline wj_val wj_arg(int argc, wj_val *argv, int i) { return i < argc ? argv[i] : WJ_UNDEFINED; }
/* "Failed to execute 'f': n arguments required, but only m present." */
wj_val wj_throw_arity(wj_ctx *ctx, const char *what, int required, int given);

enum { WJ_ENFORCE_RANGE = 1, WJ_CLAMP = 2 };
/* integer types of `bits` (8, 16, 32): ToNumber, then modulo (or [EnforceRange] / [Clamp]) */
bool wj_to_int32(wj_ctx *ctx, wj_val v, int32_t *out, int bits, int mode);
bool wj_to_uint32(wj_ctx *ctx, wj_val v, uint32_t *out, int bits, int mode);
bool wj_to_int64(wj_ctx *ctx, wj_val v, int64_t *out, int mode);
bool wj_to_uint64(wj_ctx *ctx, wj_val v, uint64_t *out, int mode);
/* double / unrestricted double: `restricted` refuses NaN and infinities (TypeError) */
bool wj_to_double(wj_ctx *ctx, wj_val v, double *out, bool restricted);

enum {
    WJ_STR_NULLABLE   = 1 << 0,   /* null (and undefined for an optional) give ptr = NULL */
    WJ_STR_NULL_EMPTY = 1 << 1,   /* [LegacyNullToEmptyString] */
    WJ_STR_OPTIONAL   = 1 << 2,   /* undefined gives ptr = NULL (no default) */
    WJ_STR_USV        = 1 << 3,   /* USVString: lone surrogates become U+FFFD */
};
/* DOMString / USVString as UTF-8; undefined takes `def` unless optional or nullable. Free with wj_str_free. */
bool wj_to_str(wj_ctx *ctx, wj_val v, wj_str *out, int flags, const char *def);
void wj_str_free(wj_ctx *ctx, wj_str *s);
/* An IDL enum value: `s` must be one of `values` (NULL-terminated), else TypeError (and `s` is freed). */
bool wj_check_enum(wj_ctx *ctx, wj_str *s, const char *const *values, const char *type);
/* The index of `s` in `values`, -1 when absent. */
int wj_enum_index(const wj_str *s, const char *const *values);

/* An argument of interface type: the handle behind a platform object of `iface` (or a descendant); null/undefined
 * accepted when `nullable` (handle 0). TypeError `message` otherwise. */
bool wj_to_handle(wj_ctx *ctx, wj_val v, int iface, bool nullable, uint64_t *out, const char *message);

/* ---- generic members ---- */

/* event handler IDL attributes (on<type>): get / set, `special` 1 = OnErrorEventHandler, 2 = OnBeforeUnload */
wj_val wj_event_handler_get(wj_ctx *ctx, wj_val this_val, int iface, const char *type);
wj_val wj_event_handler_set(wj_ctx *ctx, wj_val this_val, int iface, const char *type, wj_val v, int special);
/* [Reflect]: an IDL attribute that reads and writes a content attribute (runtime/reflect.c) */
enum { WJ_REFLECT_STRING, WJ_REFLECT_NULLABLE_STRING, WJ_REFLECT_URL, WJ_REFLECT_BOOL, WJ_REFLECT_LONG, WJ_REFLECT_ULONG, WJ_REFLECT_DOUBLE };
/* mode: 0 plain, 1 non-negative, 2 positive, 3 positive with fallback, 4 clamped to [lo, hi] */
wj_val wj_reflect_get(wj_ctx *ctx, wj_val this_val, int iface, const char *name, int kind, double def, int mode, double lo, double hi);
wj_val wj_reflect_set(wj_ctx *ctx, wj_val this_val, int iface, const char *name, int kind, wj_val v, int mode, double lo, double hi);
/* CSSStyleDeclaration's attribute of a CSS property (name in CSS syntax: "margin-top") */
wj_val wj_css_property_get(wj_ctx *ctx, wj_val this_val, const char *property);
wj_val wj_css_property_set(wj_ctx *ctx, wj_val this_val, const char *property, wj_val v);
/* [PutForwards=target]: this[name][target] = v */
wj_val wj_put_forwards(wj_ctx *ctx, wj_val this_val, const char *name, const char *target, wj_val v);
/* [Replaceable]: an own data property shadows the accessor */
wj_val wj_replaceable_setter(wj_ctx *ctx, wj_val this_val, wj_val v);
/* [LegacyLenientSetter]: ignored */
wj_val wj_lenient_setter(wj_ctx *ctx, wj_val this_val, wj_val v);
/* `stringifier attribute`: toString() returns the attribute (the member's getter is in the data of the function) */
wj_val wj_stringifier(wj_ctx *ctx, wj_val this_val, int argc, wj_val *argv);

/* ---- promises of the browser (runtime/promise.c) ---- */

/* How the value of a browser promise (module async: an i64 and a text) becomes the JavaScript value it is fulfilled
 * with; a rejection's code becomes the exception it names (TypeError, DOMException "AbortError"...). */
enum {
    WJ_HOST_UNDEFINED = 0,   /* undefined */
    WJ_HOST_NUMBER,          /* the promise's value */
    WJ_HOST_BOOL,
    WJ_HOST_TEXT,            /* the promise's text */
    WJ_HOST_ARRAYBUFFER,     /* the value is a buffer handle: an ArrayBuffer of its bytes (the buffer is released) */
    WJ_HOST_UINT8ARRAY,      /* the same, as a Uint8Array */
};
/* `settle`, when given, makes the value (fulfilled) or the reason (rejected) instead of the kind's conversion; it
 * returns WJ_EXCEPTION to reject with the pending exception. `data` is kept until then and given back. */
typedef wj_val (*wj_host_settle)(wj_ctx *ctx, int state, uint64_t host, int64_t value, wj_val data, bool *reject);
/* A JavaScript promise settled by the browser's promise `host` (the realm's: released once it settled). */
wj_val wj_promise_from_host(wj_ctx *ctx, uint64_t host, int kind, wj_host_settle settle, wj_val data);
/* The pending exception as a rejected promise (operations returning promises never throw: Web IDL). */
wj_val wj_promise_reject_pending(wj_ctx *ctx);

/* ---- misc ---- */

void *wj_malloc(size_t n);
void wj_free(void *p);

/* Reports an exception as uncaught: the global's error event, then the browser's console. Takes `exc`. */
void wj_report_exception(wj_ctx *ctx, wj_val exc);

/* At every entry from the browser, before running script: sets the recursion budget from the outermost entry only (an
 * entry nested in a browser call keeps the frames below it counted). NULL: the realm's context. */
void wj_stack_enter(wj_ctx *ctx);
/* The recursion budget is spent (C code recursing on its own checks it: no exception thrown). */
bool wj_stack_exhausted(void);

#endif
