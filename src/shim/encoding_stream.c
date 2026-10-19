/* Streaming decoder for TextDecoder (Encoding Standard) over Lexbor's encoding decoders.
 *
 * Lexbor's lxb_encoding_decode_t already keeps the state of a multi-byte sequence cut at the end of a chunk (status
 * LXB_STATUS_CONTINUE), so `stream: true` is a matter of keeping that struct alive between calls. What the Encoding
 * Standard adds on top is done here:
 *   * error mode: "replacement" (U+FFFD) or "fatal" (no replacement set: Lexbor then returns LXB_STATUS_ERROR);
 *   * the BOM: for UTF-8, UTF-16LE and UTF-16BE a leading U+FEFF is dropped once per stream unless ignoreBOM;
 *   * flush: at the end of a non-streaming call an incomplete sequence becomes U+FFFD (or a fatal error), and the next
 *     call starts a new stream.
 * Output is UTF-8 in a malloc'd buffer (release with wb_free). One decoder is used by one thread at a time.
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "lexbor/encoding/encoding.h"

#define WB_CP_BUF 1024

typedef struct {
    lxb_encoding_decode_t        dec;
    const lxb_encoding_data_t   *enc;
    lxb_codepoint_t              cp[WB_CP_BUF];
    int                          fatal;
    int                          ignore_bom;
    int                          bom_seen;
    int                          bom_applies;
} wb_decoder;

typedef struct {
    uint8_t *data;
    size_t   len;
    size_t   cap;
    int      failed;
} wb_out;

static void out_reserve(wb_out *o, size_t n)
{
    if (o->failed || o->len + n <= o->cap) { return; }
    size_t cap = o->cap ? o->cap : 256;
    while (cap < o->len + n) { cap *= 2; }
    uint8_t *p = (uint8_t *) realloc(o->data, cap);
    if (p == NULL) { o->failed = 1; return; }
    o->data = p;
    o->cap = cap;
}

static void out_cp(wb_out *o, lxb_codepoint_t c)
{
    out_reserve(o, 4);
    if (o->failed) { return; }
    uint8_t *d = o->data + o->len;
    if (c >= 0xD800 && c <= 0xDFFF) { c = 0xFFFD; }   /* never emit a surrogate */
    if (c < 0x80)         { d[0] = (uint8_t) c; o->len += 1; }
    else if (c < 0x800)   { d[0] = (uint8_t) (0xC0 | (c >> 6)); d[1] = (uint8_t) (0x80 | (c & 0x3F)); o->len += 2; }
    else if (c < 0x10000) { d[0] = (uint8_t) (0xE0 | (c >> 12)); d[1] = (uint8_t) (0x80 | ((c >> 6) & 0x3F)); d[2] = (uint8_t) (0x80 | (c & 0x3F)); o->len += 3; }
    else if (c <= 0x10FFFF) {
        d[0] = (uint8_t) (0xF0 | (c >> 18)); d[1] = (uint8_t) (0x80 | ((c >> 12) & 0x3F));
        d[2] = (uint8_t) (0x80 | ((c >> 6) & 0x3F)); d[3] = (uint8_t) (0x80 | (c & 0x3F)); o->len += 4;
    }
    else { d[0] = 0xEF; d[1] = 0xBF; d[2] = 0xBD; o->len += 3; }
}

/* The decoder keeps this pointer for its whole life: LXB_ENCODING_REPLACEMENT_BUFFER is a compound literal, which
 * would die with decoder_init's block (MSVC 14.51 reuses that stack slot: U+0000 came out instead of U+FFFD). */
static const lxb_codepoint_t wb_replacement[LXB_ENCODING_REPLACEMENT_BUFFER_LEN] = { LXB_ENCODING_REPLACEMENT_CODEPOINT };

static int decoder_init(wb_decoder *d)
{
    if (lxb_encoding_decode_init(&d->dec, d->enc, d->cp, WB_CP_BUF) != LXB_STATUS_OK) { return -1; }
    if (!d->fatal) {
        if (lxb_encoding_decode_replace_set(&d->dec, wb_replacement, LXB_ENCODING_REPLACEMENT_BUFFER_LEN) != LXB_STATUS_OK) { return -1; }
    }
    d->bom_seen = 0;
    return 0;
}

/* NULL when the label is unknown or names the "replacement" encoding (TextDecoder throws RangeError for both). */
wb_decoder *wb_decoder_create(const char *label, size_t label_len, int fatal, int ignore_bom)
{
    const lxb_encoding_data_t *enc = lxb_encoding_data_by_pre_name((const lxb_char_t *) label, label_len);
    if (enc == NULL || enc->encoding == LXB_ENCODING_REPLACEMENT || enc->encoding == LXB_ENCODING_DEFAULT
        || enc->encoding == LXB_ENCODING_AUTO || enc->encoding == LXB_ENCODING_UNDEFINED) {
        return NULL;
    }
    wb_decoder *d = (wb_decoder *) calloc(1, sizeof(wb_decoder));
    if (d == NULL) { return NULL; }
    d->enc = enc;
    d->fatal = fatal != 0;
    d->ignore_bom = ignore_bom != 0;
    d->bom_applies = enc->encoding == LXB_ENCODING_UTF_8 || enc->encoding == LXB_ENCODING_UTF_16LE
                     || enc->encoding == LXB_ENCODING_UTF_16BE;
    if (decoder_init(d) != 0) { free(d); return NULL; }
    return d;
}

void wb_decoder_destroy(wb_decoder *d) { free(d); }

/* The encoding's name, lower case as TextDecoder.encoding reports it ("utf-8", "windows-1252"). */
size_t wb_decoder_name(const wb_decoder *d, char *out, size_t cap)
{
    const char *name = (const char *) d->enc->name;
    size_t n = strlen(name);
    if (n > cap) { return n; }
    for (size_t i = 0; i < n; i++) {
        char c = name[i];
        out[i] = (c >= 'A' && c <= 'Z') ? (char) (c + 32) : c;
    }
    return n;
}

static void emit(wb_decoder *d, wb_out *o)
{
    size_t used = lxb_encoding_decode_buf_used(&d->dec);
    for (size_t i = 0; i < used; i++) {
        lxb_codepoint_t c = d->cp[i];
        if (d->bom_applies && !d->bom_seen) {
            d->bom_seen = 1;
            if (c == 0xFEFF && !d->ignore_bom) { continue; }
        }
        d->bom_seen = 1;
        out_cp(o, c);
    }
    lxb_encoding_decode_buf_used_set(&d->dec, 0);
}

/* Decodes one chunk. `flush` = the call is not `stream: true`: pending bytes are finished and the stream restarts.
 * Returns 0 and the UTF-8 output; 1 for a fatal-mode error (TypeError; the decoder starts over); -1 when out of memory.
 */
int wb_decoder_decode(wb_decoder *d, const uint8_t *data, size_t len, int flush, uint8_t **out, size_t *out_len)
{
    *out = NULL;
    *out_len = 0;
    wb_out o = {0};
    const lxb_char_t *p = data;
    const lxb_char_t *end = data + len;
    lxb_status_t st;

    for (;;) {
        st = d->enc->decode(&d->dec, &p, end);
        emit(d, &o);
        if (st == LXB_STATUS_SMALL_BUFFER) { continue; }
        break;
    }
    if (st == LXB_STATUS_ERROR) {
        free(o.data);
        decoder_init(d);
        return 1;
    }
    if (flush) {
        st = lxb_encoding_decode_finish(&d->dec);
        emit(d, &o);
        if (st == LXB_STATUS_ERROR) {
            free(o.data);
            decoder_init(d);
            return 1;
        }
        decoder_init(d);
    }
    if (o.failed) { free(o.data); return -1; }
    out_reserve(&o, 1);
    if (o.failed) { free(o.data); return -1; }
    *out = o.data;
    *out_len = o.len;
    return 0;
}
