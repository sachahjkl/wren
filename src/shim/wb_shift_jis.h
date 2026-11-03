/* The Shift_JIS decoder and encoder of the Encoding Standard where Lexbor's differ (wb_shift_jis.c). */
#include "lexbor/encoding/encoding.h"

lxb_status_t wb_decode_shift_jis(lxb_encoding_decode_t *ctx, const lxb_char_t **data, const lxb_char_t *end);
int8_t wb_encode_shift_jis_single(lxb_encoding_encode_t *ctx, lxb_char_t **data, const lxb_char_t *end, lxb_codepoint_t cp);
