/* Shims over Lexbor's WHATWG URL parser and encoding converters. Results are returned as malloc'd buffers
 * (release with wb_free) so no Lexbor structure leaks into the caller. Every call builds and destroys its own parser:
 * safe from any thread.
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "lexbor/url/url.h"
#include "lexbor/encoding/encoding.h"
#include "lexbor/html/encoding.h"

void wb_free(void *p) { free(p); }

typedef struct {
    uint8_t *data;
    size_t   len;
    size_t   cap;
    int      failed;
} wb_buf;

static int buf_append(wb_buf *b, const uint8_t *s, size_t n)
{
    if (b->failed) { return -1; }
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->len + n + 1) { cap *= 2; }
        uint8_t *p = (uint8_t *) realloc(b->data, cap);
        if (p == NULL) { b->failed = 1; return -1; }
        b->data = p;
        b->cap = cap;
    }
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = 0;
    return 0;
}

static lxb_status_t serialize_cb(const lxb_char_t *data, size_t len, void *ctx)
{
    return buf_append((wb_buf *) ctx, data, len) == 0 ? LXB_STATUS_OK : LXB_STATUS_ERROR_MEMORY_ALLOCATION;
}

/* Parses `input` (resolving against `base` when base != NULL) per the WHATWG URL Standard and returns the serialized
 * URL (href). Returns 0 on success, non-zero when the input is not a valid URL (or the base is not).
 */
int wb_url_parse(const uint8_t *input, size_t len, const uint8_t *base, size_t base_len,
                 uint8_t **out, size_t *out_len)
{
    *out = NULL;
    *out_len = 0;

    lxb_url_parser_t *parser = lxb_url_parser_create();
    if (parser == NULL) { return -1; }
    if (lxb_url_parser_init(parser, NULL) != LXB_STATUS_OK) {
        lxb_url_parser_destroy(parser, true);
        return -1;
    }

    int rc = -1;
    lxb_url_t *base_url = NULL;
    lxb_url_t *url = NULL;
    wb_buf buf = {0};

    if (base != NULL) {
        base_url = lxb_url_parse(parser, NULL, (const lxb_char_t *) base, base_len);
        if (base_url == NULL) { goto done; }
    }
    url = lxb_url_parse(parser, base_url, (const lxb_char_t *) input, len);
    if (url == NULL) { goto done; }

    if (lxb_url_serialize(url, serialize_cb, &buf, false) != LXB_STATUS_OK || buf.failed) { goto done; }
    if (buf.data == NULL) { buf_append(&buf, (const uint8_t *) "", 0); }
    *out = buf.data;
    *out_len = buf.len;
    buf.data = NULL;
    rc = 0;

done:
    free(buf.data);
    /* URLs live in the parser's memory object: destroying it releases base_url and url together */
    lxb_url_parser_memory_destroy(parser);
    lxb_url_parser_destroy(parser, true);
    return rc;
}

/* Converts `data` from the encoding named `label` (any WHATWG label) to UTF-8. Invalid sequences become U+FFFD.
 * Returns 0 on success; 1 when the label is unknown (nothing written); other values on failure.
 */
int wb_decode_to_utf8(const uint8_t *data, size_t len, const char *label, size_t label_len,
                      uint8_t **out, size_t *out_len)
{
    *out = NULL;
    *out_len = 0;

    const lxb_encoding_data_t *from = lxb_encoding_data_by_pre_name((const lxb_char_t *) label, label_len);
    if (from == NULL) { return 1; }
    const lxb_encoding_data_t *to = lxb_encoding_data(LXB_ENCODING_UTF_8);

    lxb_encoding_decode_t decode;
    lxb_encoding_encode_t encode;
    lxb_codepoint_t cp[1024];
    lxb_char_t outbuf[4096];

    if (lxb_encoding_decode_init(&decode, from, cp, sizeof(cp) / sizeof(cp[0])) != LXB_STATUS_OK) { return -1; }
    if (lxb_encoding_decode_replace_set(&decode, LXB_ENCODING_REPLACEMENT_BUFFER, LXB_ENCODING_REPLACEMENT_BUFFER_LEN) != LXB_STATUS_OK) { return -1; }
    if (lxb_encoding_encode_init(&encode, to, outbuf, sizeof(outbuf)) != LXB_STATUS_OK) { return -1; }
    if (lxb_encoding_encode_replace_set(&encode, LXB_ENCODING_REPLACEMENT_BYTES, LXB_ENCODING_REPLACEMENT_SIZE) != LXB_STATUS_OK) { return -1; }

    wb_buf buf = {0};
    const lxb_char_t *p = data;
    const lxb_char_t *end = data + len;
    lxb_status_t ds;

    do {
        ds = from->decode(&decode, &p, end);
        const lxb_codepoint_t *cp_ref = cp;
        const lxb_codepoint_t *cp_end = cp + lxb_encoding_decode_buf_used(&decode);
        lxb_status_t es;
        do {
            es = to->encode(&encode, &cp_ref, cp_end);
            if (es == LXB_STATUS_ERROR) { cp_ref++; es = LXB_STATUS_SMALL_BUFFER; }
            buf_append(&buf, outbuf, lxb_encoding_encode_buf_used(&encode));
            lxb_encoding_encode_buf_used_set(&encode, 0);
        } while (es == LXB_STATUS_SMALL_BUFFER);
        lxb_encoding_decode_buf_used_set(&decode, 0);
    } while (ds == LXB_STATUS_SMALL_BUFFER);

    (void) lxb_encoding_decode_finish(&decode);
    if (lxb_encoding_decode_buf_used(&decode)) {
        const lxb_codepoint_t *cp_ref = cp;
        const lxb_codepoint_t *cp_end = cp + lxb_encoding_decode_buf_used(&decode);
        (void) to->encode(&encode, &cp_ref, cp_end);
        buf_append(&buf, outbuf, lxb_encoding_encode_buf_used(&encode));
        lxb_encoding_encode_buf_used_set(&encode, 0);
    }

    if (buf.failed) { free(buf.data); return -1; }
    if (buf.data == NULL) { buf_append(&buf, (const uint8_t *) "", 0); }
    *out = buf.data;
    *out_len = buf.len;
    return 0;
}

/* Canonical (WHATWG) name for a label, e.g. "latin1" -> "windows-1252". Returns the length, 0 if unknown. */
size_t wb_encoding_canonical_name(const char *label, size_t label_len, char *out, size_t cap)
{
    const lxb_encoding_data_t *d = lxb_encoding_data_by_pre_name((const lxb_char_t *) label, label_len);
    if (d == NULL) { return 0; }
    size_t n = strlen((const char *) d->name);
    if (n + 1 > cap) { return 0; }
    memcpy(out, d->name, n + 1);
    return n;
}

/* The HTML encoding sniffing prescan (the first 1024 bytes, <meta charset> / <meta http-equiv>). Writes the WHATWG
 * name found into `out` and returns its length; 0 when the document does not declare one.
 */
size_t wb_html_prescan_charset(const uint8_t *data, size_t len, char *out, size_t cap)
{
    lxb_html_encoding_t em;
    if (lxb_html_encoding_init(&em) != LXB_STATUS_OK) { return 0; }
    size_t n = 0;
    size_t prescan = len < 1024 ? len : 1024;
    if (lxb_html_encoding_determine(&em, (const lxb_char_t *) data, (const lxb_char_t *) data + prescan) == LXB_STATUS_OK) {
        lxb_html_encoding_entry_t *e = lxb_html_encoding_meta_entry(&em, 0);
        if (e != NULL && e->end > e->name) {
            size_t l = (size_t) (e->end - e->name);
            n = wb_encoding_canonical_name((const char *) e->name, l, out, cap);
        }
    }
    lxb_html_encoding_destroy(&em, false);
    return n;
}
