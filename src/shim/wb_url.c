/* Shims over Lexbor's WHATWG URL parser and encoding converters. Results are returned as malloc'd buffers
 * (release with wb_free) so no Lexbor structure leaks into the caller. Every call builds and destroys its own parser:
 * safe from any thread.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "lexbor/url/url.h"
#include "lexbor/encoding/encoding.h"
#include "lexbor/html/encoding.h"
#include "wb_encodings.h"

#define WB_CODEPOINT_BYTES 16   /* room for one code point in any encoding (ISO-2022-JP's escape sequences included), or a "&#N;" */

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

/* The encoding named by a WHATWG label; UTF-8 for an empty or unknown one. */
static lxb_encoding_t encoding_of(const char *label, size_t label_len)
{
    const lxb_encoding_data_t *d = label_len ? wb_encoding_by_label(label, label_len) : NULL;
    return d != NULL ? d->encoding : LXB_ENCODING_UTF_8;
}

/* The bytes of `cp` in `enc` where our encoder (wb_encode_single_fn) and Lexbor's differ: their count, else 0. */
static int8_t bytes_not_lexbors(const lxb_encoding_data_t *enc, lxb_codepoint_t cp, lxb_char_t ours[WB_CODEPOINT_BYTES])
{
    lxb_char_t theirs[WB_CODEPOINT_BYTES];
    lxb_char_t *w_ours = ours, *w_theirs = theirs;
    lxb_encoding_encode_t e_ours, e_theirs;
    (void) lxb_encoding_encode_init_single(&e_ours, enc);
    (void) lxb_encoding_encode_init_single(&e_theirs, enc);
    int8_t n = wb_encode_single_fn(enc)(&e_ours, &w_ours, ours + WB_CODEPOINT_BYTES, cp);
    int8_t m = enc->encode_single(&e_theirs, &w_theirs, theirs + WB_CODEPOINT_BYTES, cp);
    if (n <= 0 || (n == m && memcmp(ours, theirs, (size_t) n) == 0)) { return 0; }
    return n;
}

/* `input` with the characters of its query that Lexbor's encoder of `enc` gets wrong (wb_encode_single_fn: the IBM
 * extensions of Shift_JIS, the code points GB18030-2022 moved) percent-encoded as the standard encodes them, which the
 * URL parser keeps as they are; NULL when it has none (or out of memory). The query is what follows the first '?' that
 * comes before any '#'.
 */
static uint8_t *query_fixed(const lxb_encoding_data_t *enc, const uint8_t *input, size_t len, size_t *out_len)
{
    const uint8_t *end = input + len;
    const uint8_t *q = input;
    while (q < end && *q != '?' && *q != '#') { q++; }
    if (q == end || *q == '#') { return NULL; }
    const uint8_t *query_end = memchr(q, '#', (size_t) (end - q));
    if (query_end == NULL) { query_end = end; }
    wb_buf buf = {0};
    int changed = 0;
    buf_append(&buf, input, (size_t) (q + 1 - input));
    const lxb_char_t *p = q + 1;
    while (p < query_end) {
        const lxb_char_t *at = p;
        lxb_codepoint_t cp = lxb_encoding_decode_valid_utf_8_single(&p, query_end);
        lxb_char_t ours[WB_CODEPOINT_BYTES];
        int8_t n = cp <= LXB_ENCODING_DECODE_MAX_CODEPOINT ? bytes_not_lexbors(enc, cp, ours) : 0;
        if (n == 0) { buf_append(&buf, at, (size_t) (p - at)); continue; }
        for (int8_t i = 0; i < n; i++) {
            /* (the bytes of the special-query percent-encode set escaped, the others as they are: as the parser would) */
            lxb_char_t b = ours[i];
            if (b > ' ' && b < 0x7F && strchr("\"#<>'", b) == NULL) { buf_append(&buf, &b, 1); continue; }
            char escaped[sizeof("%XX")];
            snprintf(escaped, sizeof(escaped), "%%%02X", b);
            buf_append(&buf, (const uint8_t *) escaped, sizeof(escaped) - 1);
        }
        changed = 1;
    }
    buf_append(&buf, query_end, (size_t) (end - query_end));
    if (!changed || buf.failed) { free(buf.data); return NULL; }
    *out_len = buf.len;
    return buf.data;
}
/* Parses `input` (resolving against `base` when base != NULL) per the WHATWG URL Standard and returns the serialized
 * URL (href). The query of a special URL is encoded in `encoding` (a WHATWG label: the document's, "encoding-parse a
 * URL"; empty = UTF-8). Returns 0 on success, non-zero when the input is not a valid URL (or the base is not).
 */
int wb_url_parse(const uint8_t *input, size_t len, const uint8_t *base, size_t base_len,
                 const char *encoding, size_t encoding_len, uint8_t **out, size_t *out_len)
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
    lxb_encoding_t query_encoding = encoding_of(encoding, encoding_len);
    (void) lxb_url_parse_basic(parser, NULL, base_url, (const lxb_char_t *) input, len, LXB_URL_STATE__UNDEF, query_encoding);
    url = parser->url;
    if (url == NULL) { goto done; }
    /* a special URL's query in an encoding Lexbor's encoder gets wrong: what it gets wrong goes in percent-encoded, and it
     * is parsed again */
    const lxb_encoding_data_t *qenc = lxb_encoding_data(query_encoding);
    lxb_url_scheme_type_t scheme = url->scheme.type;
    if (wb_encode_single_fn(qenc) != qenc->encode_single && scheme >= LXB_URL_SCHEMEL_TYPE_HTTP
        && scheme != LXB_URL_SCHEMEL_TYPE_WS && scheme != LXB_URL_SCHEMEL_TYPE_WSS) {
        size_t fixed_len = 0;
        uint8_t *fixed = query_fixed(qenc, input, len, &fixed_len);
        if (fixed != NULL) {
            (void) lxb_url_parse_basic(parser, NULL, base_url, fixed, fixed_len, LXB_URL_STATE__UNDEF, query_encoding);
            free(fixed);
            url = parser->url;
            if (url == NULL) { goto done; }
        }
    }

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

    const lxb_encoding_data_t *from = wb_encoding_by_label(label, label_len);
    if (from == NULL) { return 1; }
    const lxb_encoding_data_t *to = lxb_encoding_data(LXB_ENCODING_UTF_8);

    lxb_encoding_decode_f decode_fn = wb_decode_fn(from);
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
        ds = decode_fn(&decode, &p, end);
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

/* Encodes UTF-8 `data` in the encoding named `label` (Encoding Standard "encode", error mode html: a code point the
 * encoding cannot represent becomes "&#N;", itself encoded, which takes ISO-2022-JP back to ASCII). The output encoding
 * of UTF-16 and replacement is UTF-8. Returns 0 on success; other values on failure.
 */
int wb_encode_from_utf8(const uint8_t *data, size_t len, const char *label, size_t label_len,
                        uint8_t **out, size_t *out_len)
{
    *out = NULL;
    *out_len = 0;

    lxb_encoding_t e = encoding_of(label, label_len);
    if (e == LXB_ENCODING_UTF_16BE || e == LXB_ENCODING_UTF_16LE || e == LXB_ENCODING_REPLACEMENT) { e = LXB_ENCODING_UTF_8; }
    const lxb_encoding_data_t *to = lxb_encoding_data(e);
    if (to == NULL) { return -1; }

    lxb_encoding_encode_single_f encode_single = wb_encode_single_fn(to);
    lxb_encoding_encode_t encode;
    (void) lxb_encoding_encode_init_single(&encode, to);
    wb_buf buf = {0};
    lxb_char_t bytes[WB_CODEPOINT_BYTES];
    char ref[WB_CODEPOINT_BYTES];
    const lxb_char_t *p = data;
    const lxb_char_t *end = data + len;

    while (p < end) {
        lxb_codepoint_t cp = lxb_encoding_decode_valid_utf_8_single(&p, end);
        if (cp > LXB_ENCODING_DECODE_MAX_CODEPOINT) { continue; }
        lxb_char_t *w = bytes;
        int8_t n = encode_single(&encode, &w, bytes + sizeof(bytes), cp);
        if (n >= 0) { buf_append(&buf, bytes, (size_t) (w - bytes)); continue; }
        int rn = snprintf(ref, sizeof(ref), "&#%u;", (unsigned) cp);
        for (int i = 0; i < rn; i++) {
            w = bytes;
            (void) encode_single(&encode, &w, bytes + sizeof(bytes), (lxb_codepoint_t) ref[i]);
            buf_append(&buf, bytes, (size_t) (w - bytes));
        }
    }
    lxb_char_t *w = bytes;
    (void) lxb_encoding_encode_finish_single(&encode, &w, bytes + sizeof(bytes));
    buf_append(&buf, bytes, (size_t) (w - bytes));

    if (buf.failed) { free(buf.data); return -1; }
    if (buf.data == NULL) { buf_append(&buf, (const uint8_t *) "", 0); }
    *out = buf.data;
    *out_len = buf.len;
    return 0;
}

/* The WHATWG name of a label ("latin1" -> "windows-1252"), in Lexbor's static memory; NULL when unknown. */
const char *wb_encoding_name(const char *label, size_t label_len)
{
    const lxb_encoding_data_t *d = wb_encoding_by_label(label, label_len);
    return d != NULL ? (const char *) d->name : NULL;
}

/* Canonical (WHATWG) name for a label, e.g. "latin1" -> "windows-1252". Returns the length, 0 if unknown. */
size_t wb_encoding_canonical_name(const char *label, size_t label_len, char *out, size_t cap)
{
    const lxb_encoding_data_t *d = wb_encoding_by_label(label, label_len);
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
