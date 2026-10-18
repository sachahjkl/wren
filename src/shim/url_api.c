/* The setters of the URL Standard's API (href, protocol, username, ... hash) over Lexbor's lxb_url_api_*_set, which
 * implement the basic URL parser's state overrides. Each call parses `href`, applies one setter, and returns the new
 * serialization (malloc'd, release with wb_free). Safe from any thread: nothing is shared between calls.
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "lexbor/url/url.h"

typedef struct {
    uint8_t *data;
    size_t   len;
    size_t   cap;
    int      failed;
} wb_sbuf;

static lxb_status_t sbuf_cb(const lxb_char_t *data, size_t len, void *ctx)
{
    wb_sbuf *b = (wb_sbuf *) ctx;
    if (b->failed) { return LXB_STATUS_ERROR_MEMORY_ALLOCATION; }
    if (b->len + len + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->len + len + 1) { cap *= 2; }
        uint8_t *p = (uint8_t *) realloc(b->data, cap);
        if (p == NULL) { b->failed = 1; return LXB_STATUS_ERROR_MEMORY_ALLOCATION; }
        b->data = p;
        b->cap = cap;
    }
    memcpy(b->data + b->len, data, len);
    b->len += len;
    b->data[b->len] = 0;
    return LXB_STATUS_OK;
}

/* component: 0 href, 1 protocol, 2 username, 3 password, 4 host, 5 hostname, 6 port, 7 pathname, 8 search, 9 hash.
 * Returns 0 with the new href; 1 when the href setter got an invalid URL (TypeError); -1 on other failures. A setter whose
 * value the standard ignores (a bad port, a host on a URL without one...) succeeds and leaves the URL unchanged.
 */
int wb_url_set(const uint8_t *href, size_t href_len, int component, const uint8_t *value, size_t value_len,
               uint8_t **out, size_t *out_len)
{
    *out = NULL;
    *out_len = 0;
    static const uint8_t empty = 0;
    if (value == NULL) { value = &empty; value_len = 0; }

    lxb_url_parser_t *parser = lxb_url_parser_create();
    if (parser == NULL) { return -1; }
    if (lxb_url_parser_init(parser, NULL) != LXB_STATUS_OK) { lxb_url_parser_destroy(parser, true); return -1; }

    int rc = -1;
    wb_sbuf buf = {0};
    lxb_url_t *url = lxb_url_parse(parser, NULL, href, href_len);
    if (url == NULL) { goto done; }

    lxb_status_t st = LXB_STATUS_OK;
    switch (component) {
    case 0: st = lxb_url_api_href_set(url, parser, value, value_len); break;
    case 1: st = lxb_url_api_protocol_set(url, parser, value, value_len); break;
    case 2: st = lxb_url_api_username_set(url, value, value_len); break;
    case 3: st = lxb_url_api_password_set(url, value, value_len); break;
    case 4: st = lxb_url_api_host_set(url, parser, value, value_len); break;
    case 5: st = lxb_url_api_hostname_set(url, parser, value, value_len); break;
    case 6: st = lxb_url_api_port_set(url, parser, value, value_len); break;
    case 7: st = lxb_url_api_pathname_set(url, parser, value, value_len); break;
    case 8: st = lxb_url_api_search_set(url, parser, value, value_len); break;
    case 9: st = lxb_url_api_hash_set(url, parser, value, value_len); break;
    default: goto done;
    }
    if (st != LXB_STATUS_OK) {
        if (component == 0) { rc = 1; goto done; }
        /* the standard's setters never throw: a refused value leaves the URL as it was */
        lxb_url_parser_memory_destroy(parser);
        lxb_url_parser_destroy(parser, true);
        uint8_t *copy = (uint8_t *) malloc(href_len + 1);
        if (copy == NULL) { return -1; }
        memcpy(copy, href, href_len);
        copy[href_len] = 0;
        *out = copy;
        *out_len = href_len;
        return 0;
    }
    if (lxb_url_serialize(url, sbuf_cb, &buf, false) != LXB_STATUS_OK || buf.failed) { goto done; }
    if (buf.data == NULL) { sbuf_cb((const lxb_char_t *) "", 0, &buf); }
    if (buf.failed) { goto done; }
    *out = buf.data;
    *out_len = buf.len;
    buf.data = NULL;
    rc = 0;

done:
    free(buf.data);
    lxb_url_parser_memory_destroy(parser);
    lxb_url_parser_destroy(parser, true);
    return rc;
}
