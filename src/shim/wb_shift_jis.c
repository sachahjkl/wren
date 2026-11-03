/* The Shift_JIS decoder of the Encoding Standard, and what its encoder does of the IBM extensions (sjis_ibm, below), on
 * Lexbor's decoder state and JIS X 0208 index. Lexbor 3.0.1's own decoder takes only 0xE0 and 0xFC of the lead bytes
 * 0xE0..0xFC: the level 2 kanji and the IBM extensions of every Shift_JIS page and TextDecoder came out as U+FFFD.
 * wb_decode_fn and wb_encode_single_fn (wb_encodings.c) give these in place of Lexbor's; the protocol is Lexbor's (state
 * in ctx->u.lead, LXB_STATUS_SMALL_BUFFER when the output is full, LXB_STATUS_CONTINUE with a lead pending at the end,
 * LXB_STATUS_ERROR on an error in fatal mode).
 */
#include "lexbor/encoding/encoding.h"
#include "lexbor/encoding/multi.h"
#include "wb_shift_jis.h"

#define SJIS_TRAIL_STRIDE 188
#define SJIS_EUDC_FIRST   8836    /* pointers of the private use area */
#define SJIS_EUDC_LAST    10715
#define SJIS_EUDC_BASE    0xE000
#define SJIS_KATAKANA     0xFF61  /* half-width katakana, from byte 0xA1 */
#define SJIS_NEC_IBM_FIRST 8272   /* pointers of the NEC selected IBM extensions, which the encoder leaves out */
#define SJIS_NEC_IBM_LAST  8835
#define SJIS_IBM_FIRST    10716   /* pointers of the IBM extensions, which it takes instead */
#define SJIS_LEAD_SPLIT   0x1F    /* a pointer's lead below it is a byte from 0x81, else from 0xC1 */
#define SJIS_TRAIL_SPLIT  0x3F    /* a pointer's trail below it is a byte from 0x40, else from 0x41 */

static void sjis_emit(lxb_encoding_decode_t *ctx, lxb_codepoint_t cp) { ctx->buffer_out[ctx->buffer_used++] = cp; }

static int sjis_error(lxb_encoding_decode_t *ctx)
{
    if (ctx->replace_to == NULL) { return 0; }
    for (size_t i = 0; i < ctx->replace_len; i++) { ctx->buffer_out[ctx->buffer_used++] = ctx->replace_to[i]; }
    return 1;
}

static lxb_codepoint_t sjis_pair(unsigned lead, lxb_char_t byte)
{
    if (!((byte >= 0x40 && byte <= 0x7E) || (byte >= 0x80 && byte <= 0xFC))) { return LXB_ENCODING_ERROR_CODEPOINT; }
    unsigned pointer = (lead - (lead < 0xA0 ? 0x81 : 0xC1)) * SJIS_TRAIL_STRIDE + byte - (byte < 0x7F ? 0x40 : 0x41);
    if (pointer >= SJIS_EUDC_FIRST && pointer <= SJIS_EUDC_LAST) { return SJIS_EUDC_BASE - SJIS_EUDC_FIRST + pointer; }
    if (pointer >= sizeof(lxb_encoding_multi_jis0208_map) / sizeof(lxb_encoding_multi_jis0208_map[0])) { return LXB_ENCODING_ERROR_CODEPOINT; }
    return lxb_encoding_multi_jis0208_map[pointer];
}

lxb_status_t wb_decode_shift_jis(lxb_encoding_decode_t *ctx, const lxb_char_t **data, const lxb_char_t *end)
{
    /* every step writes one code point or one replacement: room for the larger before each */
    size_t step = ctx->replace_len > 1 ? ctx->replace_len : 1;
    const lxb_char_t *p = *data;
    ctx->status = LXB_STATUS_OK;
    while (p < end) {
        if (ctx->buffer_used + step > ctx->buffer_length) { *data = p; return LXB_STATUS_SMALL_BUFFER; }
        lxb_char_t byte = *p;
        unsigned lead = ctx->u.lead;
        if (lead != 0) {
            ctx->u.lead = 0;
            lxb_codepoint_t cp = sjis_pair(lead, byte);
            if (cp != LXB_ENCODING_ERROR_CODEPOINT) { sjis_emit(ctx, cp); p++; continue; }
            if (byte >= 0x80) { p++; }   /* an ASCII byte is decoded again, on its own */
            if (!sjis_error(ctx)) { *data = p; return LXB_STATUS_ERROR; }
            continue;
        }
        p++;
        if (byte <= 0x80) { sjis_emit(ctx, byte); }
        else if (byte >= 0xA1 && byte <= 0xDF) { sjis_emit(ctx, SJIS_KATAKANA - 0xA1 + byte); }
        else if ((byte >= 0x81 && byte <= 0x9F) || (byte >= 0xE0 && byte <= 0xFC)) { ctx->u.lead = byte; }
        else if (!sjis_error(ctx)) { *data = p; return LXB_STATUS_ERROR; }
    }
    *data = p;
    if (ctx->u.lead != 0) { ctx->status = LXB_STATUS_CONTINUE; return LXB_STATUS_CONTINUE; }
    return LXB_STATUS_OK;
}

static unsigned sjis_pointer_of(const lxb_char_t bytes[2])
{
    return (bytes[0] - (bytes[0] < 0xA0 ? 0x81 : 0xC1)) * SJIS_TRAIL_STRIDE + bytes[1] - (bytes[1] < 0x7F ? 0x40 : 0x41);
}

/* The encoder's side. The standard's "index Shift_JIS pointer" leaves out the NEC selected IBM extensions (pointers 8272
 * to 8835): a character there and among the IBM extensions (from pointer 10716, lead bytes 0xFA..0xFC) is encoded as
 * the latter. Lexbor 3.0.1 does the opposite: it takes the NEC pointer, and fails a character whose first pointer is
 * past them. The two bytes the standard gives `cp` when Lexbor's differ: 1 when written to `out`, else 0. */
static int sjis_ibm(lxb_codepoint_t cp, lxb_char_t out[2])
{
    lxb_encoding_encode_t encode;
    lxb_char_t lexbor[2];
    lxb_char_t *w = lexbor;
    (void) lxb_encoding_encode_init_single(&encode, lxb_encoding_data(LXB_ENCODING_SHIFT_JIS));
    int8_t n = lxb_encoding_encode_shift_jis_single(&encode, &w, lexbor + sizeof(lexbor), cp);
    if (n == 2) {
        unsigned pointer = sjis_pointer_of(lexbor);
        if (pointer < SJIS_NEC_IBM_FIRST || pointer > SJIS_NEC_IBM_LAST) { return 0; }
    } else if (n != LXB_ENCODING_ENCODE_ERROR) {
        return 0;
    }
    size_t count = sizeof(lxb_encoding_multi_jis0208_map) / sizeof(lxb_encoding_multi_jis0208_map[0]);
    for (size_t pointer = SJIS_IBM_FIRST; pointer < count; pointer++) {
        if (lxb_encoding_multi_jis0208_map[pointer] != cp) { continue; }
        unsigned lead = (unsigned) pointer / SJIS_TRAIL_STRIDE, trail = (unsigned) pointer % SJIS_TRAIL_STRIDE;
        out[0] = (lxb_char_t) (lead + (lead < SJIS_LEAD_SPLIT ? 0x81 : 0xC1));
        out[1] = (lxb_char_t) (trail + (trail < SJIS_TRAIL_SPLIT ? 0x40 : 0x41));
        return 1;
    }
    return 0;
}

/* Lexbor's encode_single for Shift_JIS, with the IBM extensions of the standard (sjis_ibm). */
int8_t wb_encode_shift_jis_single(lxb_encoding_encode_t *ctx, lxb_char_t **data, const lxb_char_t *end, lxb_codepoint_t cp)
{
    lxb_char_t ibm[2];
    if (!sjis_ibm(cp, ibm)) { return lxb_encoding_encode_shift_jis_single(ctx, data, end, cp); }
    if (*data + sizeof(ibm) > end) { return LXB_ENCODING_ENCODE_SMALL_BUFFER; }
    *(*data)++ = ibm[0];
    *(*data)++ = ibm[1];
    return 2;
}
