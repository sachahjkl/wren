/* What the shims take of Lexbor's encodings: the encoding a label names, its decode and encode_single functions, with
 * ours where Lexbor 3.0.1 is behind the Encoding Standard. Every lookup of the shims goes through here.
 */
#include <string.h>
#include "lexbor/encoding/encoding.h"
#include "wb_encodings.h"
#include "wb_shift_jis.h"

typedef struct {
    const char     *label;
    lxb_encoding_t  encoding;
} wb_label;

/* labels the standard has added since (the UTF-16 names of other systems, unicode-1-1-utf-8's variants) */
static const wb_label added_labels[] = {
    {"csunicode",       LXB_ENCODING_UTF_16LE},
    {"iso-10646-ucs-2", LXB_ENCODING_UTF_16LE},
    {"ucs-2",           LXB_ENCODING_UTF_16LE},
    {"unicode",         LXB_ENCODING_UTF_16LE},
    {"unicodefeff",     LXB_ENCODING_UTF_16LE},
    {"unicodefffe",     LXB_ENCODING_UTF_16BE},
    {"unicode11utf8",   LXB_ENCODING_UTF_8},
    {"unicode20utf8",   LXB_ENCODING_UTF_8},
    {"x-unicode20utf8", LXB_ENCODING_UTF_8},
};

static int is_label_space(lxb_char_t c) { return c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D || c == 0x20; }

static int equal_ascii_fold(const lxb_char_t *a, size_t len, const char *b)
{
    if (strlen(b) != len) { return 0; }
    for (size_t i = 0; i < len; i++) {
        lxb_char_t c = a[i];
        if (c >= 'A' && c <= 'Z') { c = (lxb_char_t) (c + ('a' - 'A')); }
        if (c != (lxb_char_t) b[i]) { return 0; }
    }
    return 1;
}

const lxb_encoding_data_t *wb_encoding_by_label(const char *label, size_t label_len)
{
    if (label_len == 0) { return NULL; }
    const lxb_char_t *p = (const lxb_char_t *) label;
    const lxb_encoding_data_t *d = lxb_encoding_data_by_pre_name(p, label_len);
    if (d != NULL) { return d; }
    const lxb_char_t *end = p + label_len;
    while (p < end && is_label_space(*p)) { p++; }
    while (end > p && is_label_space(end[-1])) { end--; }
    for (size_t i = 0; i < sizeof(added_labels) / sizeof(added_labels[0]); i++) {
        if (equal_ascii_fold(p, (size_t) (end - p), added_labels[i].label)) { return lxb_encoding_data(added_labels[i].encoding); }
    }
    return NULL;
}

lxb_encoding_decode_f wb_decode_fn(const lxb_encoding_data_t *enc)
{
    return enc->encoding == LXB_ENCODING_SHIFT_JIS ? wb_decode_shift_jis : enc->decode;
}

typedef struct {
    lxb_codepoint_t pua;    /* GB18030-2005's code point */
    lxb_codepoint_t now;    /* GB18030-2022's, which Lexbor encodes to the same bytes */
} wb_gb18030_moved;

/* The standard's gb18030 encoder still takes the private use code points GB18030-2022 gave real characters to */
static const wb_gb18030_moved gb18030_moved[] = {
    {0xE78D, 0xFE10}, {0xE78E, 0xFE12}, {0xE78F, 0xFE11}, {0xE790, 0xFE13}, {0xE791, 0xFE14}, {0xE792, 0xFE15},
    {0xE793, 0xFE16}, {0xE794, 0xFE17}, {0xE795, 0xFE18}, {0xE796, 0xFE19}, {0xE81E, 0x9FB4}, {0xE826, 0x9FB5},
    {0xE82B, 0x9FB6}, {0xE82C, 0x9FB7}, {0xE832, 0x9FB8}, {0xE843, 0x9FB9}, {0xE854, 0x9FBA}, {0xE864, 0x9FBB},
};

static lxb_codepoint_t gb18030_now(lxb_codepoint_t cp)
{
    for (size_t i = 0; i < sizeof(gb18030_moved) / sizeof(gb18030_moved[0]); i++) {
        if (gb18030_moved[i].pua == cp) { return gb18030_moved[i].now; }
    }
    return cp;
}

static int8_t wb_encode_gbk_single(lxb_encoding_encode_t *ctx, lxb_char_t **data, const lxb_char_t *end, lxb_codepoint_t cp)
{
    return lxb_encoding_encode_gbk_single(ctx, data, end, gb18030_now(cp));
}

static int8_t wb_encode_gb18030_single(lxb_encoding_encode_t *ctx, lxb_char_t **data, const lxb_char_t *end, lxb_codepoint_t cp)
{
    return lxb_encoding_encode_gb18030_single(ctx, data, end, gb18030_now(cp));
}

lxb_encoding_encode_single_f wb_encode_single_fn(const lxb_encoding_data_t *enc)
{
    switch (enc->encoding) {
        case LXB_ENCODING_SHIFT_JIS: return wb_encode_shift_jis_single;
        case LXB_ENCODING_GBK:       return wb_encode_gbk_single;
        case LXB_ENCODING_GB18030:   return wb_encode_gb18030_single;
        default:                     return enc->encode_single;
    }
}
