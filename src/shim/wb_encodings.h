/* What the shims take of Lexbor's encodings, with ours where Lexbor 3.0.1 is behind the Encoding Standard
 * (wb_encodings.c). */
#include "lexbor/encoding/encoding.h"

/* The encoding a WHATWG label names: Lexbor's labels and those added since; NULL when none. */
const lxb_encoding_data_t *wb_encoding_by_label(const char *label, size_t label_len);

/* The decode function of an encoding: Lexbor's, but for Shift_JIS. */
lxb_encoding_decode_f wb_decode_fn(const lxb_encoding_data_t *enc);

/* The encode_single function of an encoding: Lexbor's, but for Shift_JIS (the IBM extensions), gbk and gb18030 (the
 * private use code points of GB18030-2005 that GB18030-2022 moved). */
lxb_encoding_encode_single_f wb_encode_single_fn(const lxb_encoding_data_t *enc);
