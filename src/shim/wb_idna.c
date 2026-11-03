/* The URL Standard's "domain to ASCII" on Lexbor's UTS #46 (lexbor/unicode/idna.c), where the two differ. Lexbor's URL
 * parser calls wb_idna_to_ascii in place of lxb_unicode_idna_to_ascii (its url.c is compiled with the name defined to
 * this one: src/tools/wrentool/deps/lexbor.odin, LEXBOR_RENAMES):
 *   - a domain all of ASCII is lower-cased, nothing more (beStrict is false: an xn-- label is not decoded to be checked);
 *   - another one is Lexbor's, then refused when a label of it (mapped, normalized, its xn-- labels decoded: Lexbor's
 *     ToUnicode) begins with a combining mark, has a joiner out of the context CheckJoiners allows (RFC 5892 A.1, A.2),
 *     or breaks the Bidi rule of CheckBidi in a domain with a right-to-left label (RFC 5893 §2), none of which Lexbor
 *     3.0.1 checks (LXB_UNICODE_IDNA_FLAG_CHECK_JOINERS, _CHECK_BIDI: "not implemented").
 * The code points of those rules are generated (wb_idna_tables.h: `wrentool gen idna`).
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "lexbor/encoding/encoding.h"
#include "lexbor/unicode/idna.h"
#include "wb_idna_tables.h"

#define IDNA_ZWNJ 0x200C
#define IDNA_ZWJ  0x200D
#define IDNA_DOT  0x002E
/* The labels' code points checked at once without allocating; a longer domain takes the heap. */
#define IDNA_INLINE_CPS 256

lxb_status_t wb_idna_to_ascii(lxb_unicode_idna_t *idna, const lxb_char_t *data, size_t length, lexbor_serialize_cb_f cb,
                              void *ctx, lxb_unicode_idna_flag_t flags);

/* The index of the range of `first`/`last` (sorted, apart) that holds `cp`, or -1. */
static int range_of(const uint32_t *first, const uint32_t *last, int count, lxb_codepoint_t cp)
{
    int lo = 0, hi = count - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (cp < first[mid]) { hi = mid - 1; }
        else if (cp > last[mid]) { lo = mid + 1; }
        else { return mid; }
    }
    return -1;
}

static bool is_mark(lxb_codepoint_t cp) { return range_of(wb_idna_mark_first, wb_idna_mark_last, WB_IDNA_MARK_COUNT, cp) >= 0; }
static bool is_virama(lxb_codepoint_t cp) { return range_of(wb_idna_virama_first, wb_idna_virama_last, WB_IDNA_VIRAMA_COUNT, cp) >= 0; }

/* The joining type of `cp`: 'L', 'D', 'R', 'T', or 0 (U, C: none of the rule's). */
static uint8_t joining_type(lxb_codepoint_t cp)
{
    int i = range_of(wb_idna_joining_first, wb_idna_joining_last, WB_IDNA_JOINING_COUNT, cp);
    return i >= 0 ? wb_idna_joining_class[i] : 0;
}

/* RFC 5892 A.1 (ZERO WIDTH NON-JOINER) at `at` of the label: after a virama, or between (L|D) T* and T* (R|D). */
static bool zwnj_allowed(const lxb_codepoint_t *label, size_t len, size_t at)
{
    if (at > 0 && is_virama(label[at - 1])) { return true; }
    size_t i = at;
    uint8_t t = 0;
    while (i > 0 && (t = joining_type(label[i - 1])) == 'T') { i--; }
    if (i == 0 || (t != 'L' && t != 'D')) { return false; }
    i = at + 1;
    while (i < len && (t = joining_type(label[i])) == 'T') { i++; }
    return i < len && (t == 'R' || t == 'D');
}

/* The Bidi class of `cp` as the tables name it: 'L' (no range holds it), 'R', 'A' (AL), 'N' (AN), 'E' (EN), 'S' (ES),
 * 'C' (CS), 'T' (ET), 'O' (ON), 'B' (BN), 'M' (NSM), 'X' (one the rule never allows). */
static uint8_t bidi_class(lxb_codepoint_t cp)
{
    int i = range_of(wb_idna_bidi_first, wb_idna_bidi_last, WB_IDNA_BIDI_COUNT, cp);
    return i >= 0 ? wb_idna_bidi_class[i] : 'L';
}

/* RFC 5893 §2 on one label of a domain with a right-to-left label: it begins with L (a left-to-right label) or R / AL (a
 * right-to-left one), holds only the classes its direction allows, ends (NSM aside) with L or EN, or with R, AL, EN or
 * AN, and a right-to-left label has not both EN and AN. */
static bool bidi_valid(const lxb_codepoint_t *label, size_t len)
{
    if (len == 0) { return true; }
    uint8_t first = bidi_class(label[0]);
    if (first != 'L' && first != 'R' && first != 'A') { return false; }
    bool rtl = first != 'L';
    const char *allowed = rtl ? "RANESCTOBM" : "LESCTOBM";
    bool en = false, an = false;
    for (size_t i = 0; i < len; i++) {
        uint8_t c = bidi_class(label[i]);
        if (strchr(allowed, c) == NULL) { return false; }
        en = en || c == 'E';
        an = an || c == 'N';
    }
    size_t end = len;
    while (end > 0 && bidi_class(label[end - 1]) == 'M') { end--; }
    uint8_t last = end > 0 ? bidi_class(label[end - 1]) : 'M';
    if (rtl) { return (last == 'R' || last == 'A' || last == 'E' || last == 'N') && !(en && an); }
    return last == 'L' || last == 'E';
}

/* RFC 5893 §1.4: a domain with a label that holds R, AL or AN. */
static bool bidi_domain(const lxb_codepoint_t *cps, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        uint8_t c = bidi_class(cps[i]);
        if (c == 'R' || c == 'A' || c == 'N') { return true; }
    }
    return false;
}

/* UTS #46 §4.1 step 7 (no combining mark first), CheckJoiners and, in a Bidi domain, CheckBidi on one label. */
static bool label_valid(const lxb_codepoint_t *label, size_t len, bool bidi)
{
    if (len > 0 && is_mark(label[0])) { return false; }
    for (size_t i = 0; i < len; i++) {
        if (label[i] == IDNA_ZWJ && !(i > 0 && is_virama(label[i - 1]))) { return false; }
        if (label[i] == IDNA_ZWNJ && !zwnj_allowed(label, len, i)) { return false; }
    }
    return !bidi || bidi_valid(label, len);
}

/* ToUnicode's output (UTF-8, the labels joined by '.'): each label checked. */
static lxb_status_t check_labels(const lxb_char_t *data, size_t len, void *ctx)
{
    bool *valid = ctx;
    lxb_codepoint_t inline_cps[IDNA_INLINE_CPS];
    lxb_codepoint_t *cps = len <= IDNA_INLINE_CPS ? inline_cps : malloc(len * sizeof(lxb_codepoint_t));
    if (cps == NULL) { return LXB_STATUS_ERROR_MEMORY_ALLOCATION; }
    size_t n = 0;
    for (const lxb_char_t *p = data, *end = data + len; p < end;) {
        lxb_codepoint_t cp = lxb_encoding_decode_valid_utf_8_single(&p, end);
        if (cp > LXB_ENCODING_DECODE_MAX_CODEPOINT) { *valid = false; break; }
        cps[n++] = cp;
    }
    bool bidi = *valid && bidi_domain(cps, n);
    size_t start = 0;
    for (size_t i = 0; *valid && i <= n; i++) {
        if (i < n && cps[i] != IDNA_DOT) { continue; }
        *valid = label_valid(cps + start, i - start, bidi);
        start = i + 1;
    }
    if (cps != inline_cps) { free(cps); }
    return LXB_STATUS_OK;
}

lxb_status_t wb_idna_to_ascii(lxb_unicode_idna_t *idna, const lxb_char_t *data, size_t length, lexbor_serialize_cb_f cb,
                              void *ctx, lxb_unicode_idna_flag_t flags)
{
    bool ascii = true;
    for (size_t i = 0; i < length && ascii; i++) { ascii = data[i] < 0x80; }
    if (ascii) {
        lxb_char_t inline_out[IDNA_INLINE_CPS];
        lxb_char_t *out = length <= IDNA_INLINE_CPS ? inline_out : malloc(length);
        if (out == NULL) { return LXB_STATUS_ERROR_MEMORY_ALLOCATION; }
        for (size_t i = 0; i < length; i++) { out[i] = data[i] >= 'A' && data[i] <= 'Z' ? data[i] + ('a' - 'A') : data[i]; }
        lxb_status_t status = cb(out, length, ctx);
        if (out != inline_out) { free(out); }
        return status;
    }
    bool valid = true;
    lxb_status_t status = lxb_unicode_idna_to_unicode(idna, data, length, check_labels, &valid, flags);
    lxb_unicode_idna_clean(idna);
    if (status != LXB_STATUS_OK) { return status; }
    if (!valid) { return LXB_STATUS_ERROR_UNEXPECTED_RESULT; }
    return lxb_unicode_idna_to_ascii(idna, data, length, cb, ctx, flags);
}
