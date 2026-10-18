/* Thin C shim over Lexbor: parse an HTML document (full HTML5 tree construction) and replay the resulting tree as a flat
 * stream of events. The browser builds its own DOM from the events: no Lexbor struct layout leaks into Odin, and Lexbor's
 * memory is released before wb_html_parse returns.
 *
 * The walk is iterative: hostile pages can nest elements very deeply.
 */
#include <stddef.h>
#include <stdint.h>
#include "lexbor/html/html.h"
#include "lexbor/dom/interfaces/element.h"
#include "lexbor/dom/interfaces/attr.h"
#include "lexbor/dom/interfaces/character_data.h"
#include "lexbor/dom/interfaces/document_type.h"

typedef struct {
    const uint8_t *name;
    size_t         name_len;
    const uint8_t *value;
    size_t         value_len;
} wb_attr;

typedef struct {
    void (*open)(void *user, const uint8_t *tag, size_t tag_len, const wb_attr *attrs, size_t n_attrs);
    void (*close)(void *user);
    void (*text)(void *user, const uint8_t *s, size_t len);
    void (*comment)(void *user, const uint8_t *s, size_t len);
} wb_html_sink;

#define WB_MAX_ATTRS 256

/* Returns 0 on success, a non-zero Lexbor status otherwise. `limit_depth`: elements nested deeper are not replayed. */
int wb_html_parse(const uint8_t *data, size_t len, const wb_html_sink *sink, void *user)
{
    lxb_html_document_t *doc = lxb_html_document_create();
    if (doc == NULL) { return -1; }

    lxb_status_t st = lxb_html_document_parse(doc, (const lxb_char_t *) data, len);
    if (st != LXB_STATUS_OK) {
        lxb_html_document_destroy(doc);
        return (int) st;
    }

    lxb_dom_node_t *root = lxb_dom_interface_node(doc);
    lxb_dom_node_t *node = root->first_child;

    while (node != NULL) {
        int descend = 0;
        switch (node->type) {
        case LXB_DOM_NODE_TYPE_ELEMENT: {
            lxb_dom_element_t *el = lxb_dom_interface_element(node);
            size_t tag_len = 0;
            const lxb_char_t *tag = lxb_dom_element_local_name(el, &tag_len);
            wb_attr attrs[WB_MAX_ATTRS];
            size_t n = 0;
            for (lxb_dom_attr_t *a = lxb_dom_element_first_attribute(el); a != NULL && n < WB_MAX_ATTRS;
                 a = lxb_dom_element_next_attribute(a)) {
                size_t nl = 0, vl = 0;
                const lxb_char_t *name = lxb_dom_attr_qualified_name(a, &nl);
                const lxb_char_t *value = lxb_dom_attr_value(a, &vl);
                attrs[n].name = name;   attrs[n].name_len = nl;
                attrs[n].value = value; attrs[n].value_len = value ? vl : 0;
                n++;
            }
            sink->open(user, tag, tag_len, attrs, n);
            descend = 1;
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
        default:
            break;
        }

        if (descend && node->first_child != NULL) {
            node = node->first_child;
            continue;
        }
        if (descend) { sink->close(user); }

        /* next sibling, or climb until one exists (closing the elements we leave) */
        while (node != NULL && node->next == NULL) {
            node = node->parent;
            if (node == NULL || node == root) { node = NULL; break; }
            sink->close(user);
        }
        if (node != NULL) { node = node->next; }
    }

    lxb_html_document_destroy(doc);
    return 0;
}
