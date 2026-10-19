/* Lexbor shim, second version: the tree of a parsed document or fragment replayed as events with everything the DOM
 * needs (wb_html.c gives elements, text and comments only): the doctype, the namespace of each element, and the
 * contents of <template> elements (their DocumentFragment), between template_begin / template_end.
 *
 *   wb_html_parse2           a whole document
 *   wb_html_parse_fragment   HTML's fragment parsing algorithm with a context element (innerHTML, insertAdjacentHTML):
 *                            the children of the context come out, without the context itself
 *
 * The walk is iterative: hostile markup can nest elements very deeply. Lexbor's memory is released before returning.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include "lexbor/html/html.h"
#include "lexbor/html/parser.h"
#include "lexbor/html/interfaces/template_element.h"
#include "lexbor/dom/interfaces/element.h"
#include "lexbor/dom/interfaces/attr.h"
#include "lexbor/dom/interfaces/character_data.h"
#include "lexbor/dom/interfaces/document_type.h"
#include "lexbor/tag/tag.h"

typedef struct {
    const uint8_t *name;
    size_t         name_len;
    const uint8_t *value;
    size_t         value_len;
} wb_attr2;

/* ns: 0 HTML, 1 SVG, 2 MathML, 3 another (or none) */
typedef struct {
    void (*open)(void *user, const uint8_t *tag, size_t tag_len, const wb_attr2 *attrs, size_t n_attrs, int ns);
    void (*close)(void *user);
    void (*text)(void *user, const uint8_t *s, size_t len);
    void (*comment)(void *user, const uint8_t *s, size_t len);
    void (*mode)(void *user, int compat_mode);
    void (*doctype)(void *user, const uint8_t *name, size_t name_len, const uint8_t *public_id, size_t public_len,
                    const uint8_t *system_id, size_t system_len);
    void (*template_begin)(void *user);   /* the contents of the template element just opened follow */
    void (*template_end)(void *user);
} wb_html_sink2;

#define WB_MAX_ATTRS2 256
/* templates nested deeper than this have their contents dropped (the walk recurses into template contents) */
#define WB_MAX_TEMPLATE_DEPTH 64

static int ns_code(lxb_ns_id_t ns)
{
    switch (ns) {
    case LXB_NS_HTML: return 0;
    case LXB_NS_SVG: return 1;
    case LXB_NS_MATH: return 2;
    default: return 3;
    }
}

/* Replays the children of `parent` (and their subtrees). Template contents are replayed in place of the template's
 * (empty) children, framed by template_begin / template_end. `attrs` (WB_MAX_ATTRS2 entries) is scratch space, used by
 * each open before anything else happens. */
static void replay_children(lxb_dom_node_t *parent, const wb_html_sink2 *sink, void *user, wb_attr2 *attrs, int depth)
{
    lxb_dom_node_t *node = parent->first_child;
    while (node != NULL) {
        int descend = 0;
        lxb_dom_node_t *children = NULL;
        switch (node->type) {
        case LXB_DOM_NODE_TYPE_ELEMENT: {
            lxb_dom_element_t *el = lxb_dom_interface_element(node);
            size_t tag_len = 0;
            const lxb_char_t *tag = lxb_dom_element_local_name(el, &tag_len);
            size_t n = 0;
            for (lxb_dom_attr_t *a = lxb_dom_element_first_attribute(el); a != NULL && n < WB_MAX_ATTRS2;
                 a = lxb_dom_element_next_attribute(a)) {
                size_t nl = 0, vl = 0;
                const lxb_char_t *name = lxb_dom_attr_qualified_name(a, &nl);
                const lxb_char_t *value = lxb_dom_attr_value(a, &vl);
                attrs[n].name = name;   attrs[n].name_len = nl;
                attrs[n].value = value; attrs[n].value_len = value ? vl : 0;
                n++;
            }
            sink->open(user, tag, tag_len, attrs, n, ns_code(node->ns));
            descend = 1;
            children = node->first_child;
            if (node->local_name == LXB_TAG_TEMPLATE && node->ns == LXB_NS_HTML && depth < WB_MAX_TEMPLATE_DEPTH) {
                lxb_html_template_element_t *t = lxb_html_interface_template(node);
                if (t->content != NULL && lxb_dom_interface_node(t->content)->first_child != NULL) {
                    /* the contents, then the template closes: the template has no children of its own */
                    if (sink->template_begin) { sink->template_begin(user); }
                    replay_children(lxb_dom_interface_node(t->content), sink, user, attrs, depth + 1);
                    if (sink->template_end) { sink->template_end(user); }
                }
            }
            break;
        }
        case LXB_DOM_NODE_TYPE_TEXT: {
            lxb_dom_character_data_t *cd = lxb_dom_interface_character_data(node);
            if (cd->data.length > 0) { sink->text(user, cd->data.data, cd->data.length); }
            break;
        }
        case LXB_DOM_NODE_TYPE_COMMENT: {
            lxb_dom_character_data_t *cd = lxb_dom_interface_character_data(node);
            sink->comment(user, cd->data.data, cd->data.length);
            break;
        }
        case LXB_DOM_NODE_TYPE_DOCUMENT_TYPE: {
            if (sink->doctype) {
                lxb_dom_document_type_t *dt = lxb_dom_interface_document_type(node);
                size_t nl = 0, pl = 0, sl = 0;
                const lxb_char_t *name = lxb_dom_document_type_name(dt, &nl);
                const lxb_char_t *pub = lxb_dom_document_type_public_id(dt, &pl);
                const lxb_char_t *sys = lxb_dom_document_type_system_id(dt, &sl);
                sink->doctype(user, name, name ? nl : 0, pub, pub ? pl : 0, sys, sys ? sl : 0);
            }
            break;
        }
        default:
            break;
        }

        if (descend && children != NULL) {
            node = children;
            continue;
        }
        if (descend) { sink->close(user); }

        /* next sibling, or climb until one exists (closing the elements we leave) */
        while (node != NULL && node->next == NULL) {
            node = node->parent;
            if (node == NULL || node == parent) { node = NULL; break; }
            sink->close(user);
        }
        if (node != NULL) { node = node->next; }
    }
}

int wb_html_parse2(const uint8_t *data, size_t len, const wb_html_sink2 *sink, void *user)
{
    lxb_html_document_t *doc = lxb_html_document_create();
    if (doc == NULL) { return -1; }
    lxb_status_t st = lxb_html_document_parse(doc, (const lxb_char_t *) data, len);
    if (st != LXB_STATUS_OK) {
        lxb_html_document_destroy(doc);
        return (int) st;
    }
    if (sink->mode != NULL) { sink->mode(user, (int) lxb_dom_interface_document(doc)->compat_mode); }
    wb_attr2 *attrs = (wb_attr2 *) malloc(sizeof(wb_attr2) * WB_MAX_ATTRS2);
    if (attrs == NULL) { lxb_html_document_destroy(doc); return -1; }
    replay_children(lxb_dom_interface_node(doc), sink, user, attrs, 0);
    free(attrs);
    lxb_html_document_destroy(doc);
    return 0;
}

/* `ctx_tag`: the context element's local name (lower case), `ctx_ns` its namespace code (as above); `quirks`: the
 * document's mode (0 no-quirks, 1 quirks, 2 limited-quirks), which changes how <table> closes a <p>. */
int wb_html_parse_fragment(const uint8_t *data, size_t len, const uint8_t *ctx_tag, size_t ctx_len, int ctx_ns,
                           int quirks, const wb_html_sink2 *sink, void *user)
{
    lxb_html_document_t *doc = lxb_html_document_create();
    if (doc == NULL) { return -1; }
    lxb_dom_document_t *dd = lxb_dom_interface_document(doc);
    dd->compat_mode = quirks == 1 ? LXB_DOM_DOCUMENT_CMODE_QUIRKS : quirks == 2 ? LXB_DOM_DOCUMENT_CMODE_LIMITED_QUIRKS : LXB_DOM_DOCUMENT_CMODE_NO_QUIRKS;
    lxb_dom_element_t *ctx = lxb_dom_document_create_element(dd, (const lxb_char_t *) ctx_tag, ctx_len, NULL);
    if (ctx == NULL) {
        lxb_html_document_destroy(doc);
        return -2;
    }
    lxb_dom_interface_node(ctx)->ns = ctx_ns == 1 ? LXB_NS_SVG : ctx_ns == 2 ? LXB_NS_MATH : LXB_NS_HTML;
    lxb_dom_node_t *root = lxb_html_document_parse_fragment(doc, ctx, (const lxb_char_t *) data, len);
    if (root == NULL) {
        lxb_html_document_destroy(doc);
        return -3;
    }
    wb_attr2 *attrs = (wb_attr2 *) malloc(sizeof(wb_attr2) * WB_MAX_ATTRS2);
    if (attrs == NULL) { lxb_html_document_destroy(doc); return -1; }
    replay_children(root, sink, user, attrs, 0);
    free(attrs);
    lxb_html_document_destroy(doc);
    return 0;
}
