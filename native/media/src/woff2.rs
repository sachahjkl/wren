//! WOFF2 (W3C WOFF File Format 2.0) to sfnt: Brotli decompression of the table stream, then the reverse of the
//! transforms: `glyf` and `loca` rebuilt from their seven streams, `hmtx` from its compact form, collections (a WOFF2
//! of a .ttc) back into a TrueType Collection. The input is untrusted: every count and offset is checked against what
//! the file holds before it is used, every allocation is checked against the caller's limit before it is made (fallible
//! reservations), and the Brotli output must be exactly the size the table directory announces.

use crate::{ERR_CORRUPT, ERR_TOO_MUCH_MEMORY, ERR_UNSUPPORTED};
use std::io::Read;

const TAG_GLYF: u32 = 0x676C_7966;
const TAG_LOCA: u32 = 0x6C6F_6361;
const TAG_HMTX: u32 = 0x686D_7478;
const TAG_HHEA: u32 = 0x6868_6561;
const TAG_HEAD: u32 = 0x6865_6164;
const TAG_MAXP: u32 = 0x6D61_7870;
const TAG_TTCF: u32 = 0x7474_6366;

/// The 63 tags a table entry can name by index (§4.1, Table 2).
const KNOWN_TAGS: [&[u8; 4]; 63] = [
    b"cmap", b"head", b"hhea", b"hmtx", b"maxp", b"name", b"OS/2", b"post", b"cvt ", b"fpgm", b"glyf", b"loca", b"prep",
    b"CFF ", b"VORG", b"EBDT", b"EBLC", b"gasp", b"hdmx", b"kern", b"LTSH", b"PCLT", b"VDMX", b"vhea", b"vmtx", b"BASE",
    b"GDEF", b"GPOS", b"GSUB", b"EBSC", b"JSTF", b"MATH", b"CBDT", b"CBLC", b"COLR", b"CPAL", b"SVG ", b"sbix", b"acnt",
    b"avar", b"bdat", b"bloc", b"bsln", b"cvar", b"fdsc", b"feat", b"fmtx", b"fvar", b"gvar", b"hsty", b"just", b"lcar",
    b"mort", b"morx", b"opbd", b"prop", b"trak", b"Zapf", b"Silf", b"Glat", b"Gloc", b"Feat", b"Sill",
];

const MAX_TABLES: usize = 4096;
const MAX_FONTS: usize = 4096;

type R<T> = Result<T, i32>;

/// A bounds-checked big-endian reader.
struct Buf<'a> {
    d: &'a [u8],
    p: usize,
}

impl<'a> Buf<'a> {
    fn new(d: &'a [u8]) -> Self {
        Buf { d, p: 0 }
    }
    fn left(&self) -> usize {
        self.d.len() - self.p
    }
    fn bytes(&mut self, n: usize) -> R<&'a [u8]> {
        if n > self.left() {
            return Err(ERR_CORRUPT);
        }
        let s = &self.d[self.p..self.p + n];
        self.p += n;
        Ok(s)
    }
    fn u8(&mut self) -> R<u8> {
        Ok(self.bytes(1)?[0])
    }
    fn u16(&mut self) -> R<u16> {
        let b = self.bytes(2)?;
        Ok(u16::from_be_bytes([b[0], b[1]]))
    }
    fn i16(&mut self) -> R<i16> {
        Ok(self.u16()? as i16)
    }
    fn u32(&mut self) -> R<u32> {
        let b = self.bytes(4)?;
        Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }
    /// UIntBase128 (§4.1): at most 5 bytes, no leading zero byte, no overflow of 32 bits.
    fn base128(&mut self) -> R<u32> {
        let mut acc: u32 = 0;
        for i in 0..5 {
            let b = self.u8()?;
            if i == 0 && b == 0x80 {
                return Err(ERR_CORRUPT);
            }
            if acc & 0xFE00_0000 != 0 {
                return Err(ERR_CORRUPT);
            }
            acc = (acc << 7) | (b & 0x7F) as u32;
            if b & 0x80 == 0 {
                return Ok(acc);
            }
        }
        Err(ERR_CORRUPT)
    }
    /// 255UInt16 (§6.1.1).
    fn u255(&mut self) -> R<u16> {
        let code = self.u8()?;
        Ok(match code {
            253 => self.u16()?,
            255 => self.u8()? as u16 + 253,
            254 => self.u8()? as u16 + 506,
            c => c as u16,
        })
    }
}

/// A Vec that never grows past the caller's limit and reports a refused allocation instead of aborting.
struct Out {
    v: Vec<u8>,
    max: usize,
}

impl Out {
    fn with_capacity(n: usize, max: usize) -> R<Out> {
        if n > max {
            return Err(ERR_TOO_MUCH_MEMORY);
        }
        let mut v = Vec::new();
        v.try_reserve_exact(n).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
        Ok(Out { v, max })
    }
    fn reserve(&mut self, n: usize) -> R<()> {
        if self.v.len().checked_add(n).map_or(true, |t| t > self.max) {
            return Err(ERR_TOO_MUCH_MEMORY);
        }
        self.v.try_reserve(n).map_err(|_| ERR_TOO_MUCH_MEMORY)
    }
    fn put(&mut self, b: &[u8]) -> R<()> {
        self.reserve(b.len())?;
        self.v.extend_from_slice(b);
        Ok(())
    }
    fn u8(&mut self, x: u8) -> R<()> {
        self.put(&[x])
    }
    fn u16(&mut self, x: u16) -> R<()> {
        self.put(&x.to_be_bytes())
    }
    fn u32(&mut self, x: u32) -> R<()> {
        self.put(&x.to_be_bytes())
    }
    fn pad4(&mut self) -> R<()> {
        while self.v.len() % 4 != 0 {
            self.u8(0)?;
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Default)]
struct Entry {
    tag: u32,
    orig_len: u32,
    transform_len: u32, // bytes of the table in the decompressed stream
    transformed: bool,
    src_off: usize, // offset in the decompressed stream
}

/// Bytes of the sfnt (or collection) that `data` (a WOFF2 file) decodes to, at most `max` bytes in total for the
/// decompressed stream and for the output each.
pub fn decode(data: &[u8], max: usize) -> R<Vec<u8>> {
    let mut b = Buf::new(data);
    if b.u32()? != 0x774F_4632 {
        return Err(ERR_CORRUPT);
    }
    let flavor = b.u32()?;
    let length = b.u32()? as usize;
    let num_tables = b.u16()? as usize;
    let reserved = b.u16()?;
    let total_sfnt = b.u32()? as usize;
    let total_compressed = b.u32()? as usize;
    let _major = b.u16()?;
    let _minor = b.u16()?;
    let _meta_off = b.u32()?;
    let _meta_len = b.u32()?;
    let _meta_orig = b.u32()?;
    let _priv_off = b.u32()?;
    let _priv_len = b.u32()?;
    if length != data.len() || reserved != 0 || num_tables == 0 || num_tables > MAX_TABLES {
        return Err(ERR_CORRUPT);
    }
    if total_sfnt > max {
        return Err(ERR_TOO_MUCH_MEMORY);
    }

    // table directory
    let mut entries: Vec<Entry> = Vec::new();
    entries.try_reserve_exact(num_tables).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
    let mut stream_len: u64 = 0;
    for _ in 0..num_tables {
        let flags = b.u8()?;
        let idx = (flags & 0x3F) as usize;
        let version = flags >> 6;
        let tag = if idx == 63 { b.u32()? } else { u32::from_be_bytes(*KNOWN_TAGS[idx]) };
        let orig_len = b.base128()?;
        // glyf and loca: version 0 is the transform, 3 the null transform; other tables: 0 is the null transform
        let transformed = if tag == TAG_GLYF || tag == TAG_LOCA { version == 0 } else { version != 0 };
        if transformed && tag != TAG_GLYF && tag != TAG_LOCA && !(tag == TAG_HMTX && version == 1) {
            return Err(ERR_UNSUPPORTED); // a transform this version of the format does not define
        }
        if (tag == TAG_GLYF || tag == TAG_LOCA) && version != 0 && version != 3 {
            return Err(ERR_CORRUPT);
        }
        let transform_len = if transformed { b.base128()? } else { orig_len };
        if tag == TAG_LOCA && transformed && transform_len != 0 {
            return Err(ERR_CORRUPT);
        }
        if orig_len as usize > max {
            return Err(ERR_TOO_MUCH_MEMORY);
        }
        entries.push(Entry { tag, orig_len, transform_len, transformed, src_off: stream_len as usize });
        stream_len += transform_len as u64;
        if stream_len > max as u64 {
            return Err(ERR_TOO_MUCH_MEMORY);
        }
    }
    let has = |t: u32| entries.iter().position(|e| e.tag == t);
    let glyf_t = has(TAG_GLYF).map(|i| entries[i].transformed);
    let loca_t = has(TAG_LOCA).map(|i| entries[i].transformed);
    if glyf_t != loca_t {
        return Err(ERR_CORRUPT); // both transformed or neither (and both present or neither)
    }

    // collection directory
    let mut fonts: Vec<(u32, Vec<usize>)> = Vec::new();
    let mut ttc_version = 0u32;
    if flavor == TAG_TTCF {
        ttc_version = b.u32()?;
        let n = b.u255()? as usize;
        if n == 0 || n > MAX_FONTS {
            return Err(ERR_CORRUPT);
        }
        fonts.try_reserve_exact(n).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
        for _ in 0..n {
            let nt = b.u255()? as usize;
            let fl = b.u32()?;
            if nt == 0 || nt > num_tables {
                return Err(ERR_CORRUPT);
            }
            let mut idx = Vec::new();
            idx.try_reserve_exact(nt).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
            for _ in 0..nt {
                let i = b.u255()? as usize;
                if i >= num_tables || idx.contains(&i) {
                    return Err(ERR_CORRUPT);
                }
                idx.push(i);
            }
            fonts.push((fl, idx));
        }
    } else {
        fonts.push((flavor, (0..num_tables).collect()));
    }

    // the compressed stream follows the directories directly
    let comp = b.bytes(total_compressed)?;
    let stream = brotli_exact(comp, stream_len as usize)?;

    for e in entries.iter() {
        if !e.transformed && e.src_off + e.orig_len as usize > stream.len() {
            return Err(ERR_CORRUPT);
        }
    }

    // tables in their sfnt form, each built once (collections share them)
    let mut built: Vec<Option<Vec<u8>>> = Vec::new();
    built.try_reserve_exact(num_tables).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
    built.resize(num_tables, None);
    let mut budget = max;
    for (_, idx) in fonts.iter() {
        let find = |t: u32| idx.iter().copied().find(|&i| entries[i].tag == t);
        if let (Some(gi), Some(li)) = (find(TAG_GLYF), find(TAG_LOCA)) {
            if entries[gi].transformed && built[gi].is_none() {
                let g = &entries[gi];
                let src = stream.get(g.src_off..g.src_off + g.transform_len as usize).ok_or(ERR_CORRUPT)?;
                let head = find(TAG_HEAD).map(|i| plain(&stream, &entries[i])).transpose()?.ok_or(ERR_CORRUPT)?;
                let (glyf, loca, x_mins) = rebuild_glyf(src, head, budget)?;
                if loca.len() != entries[li].orig_len as usize {
                    return Err(ERR_CORRUPT);
                }
                // the glyph count a font engine reads (maxp) must be the one loca was built for
                let maxp = find(TAG_MAXP).map(|i| plain(&stream, &entries[i])).transpose()?.ok_or(ERR_CORRUPT)?;
                if maxp.len() < 6 || u16::from_be_bytes([maxp[4], maxp[5]]) as usize != x_mins.len() {
                    return Err(ERR_CORRUPT);
                }
                budget = budget.saturating_sub(glyf.len() + loca.len());
                if let Some(hi) = find(TAG_HMTX) {
                    if entries[hi].transformed && built[hi].is_none() {
                        let h = &entries[hi];
                        let hsrc = stream.get(h.src_off..h.src_off + h.transform_len as usize).ok_or(ERR_CORRUPT)?;
                        let hhea = find(TAG_HHEA).map(|i| plain(&stream, &entries[i])).transpose()?.ok_or(ERR_CORRUPT)?;
                        let hmtx = rebuild_hmtx(hsrc, hhea, &x_mins, h.orig_len as usize)?;
                        built[hi] = Some(hmtx);
                    }
                }
                built[gi] = Some(glyf);
                built[li] = Some(loca);
            }
        }
        if let Some(hi) = find(TAG_HMTX) {
            if entries[hi].transformed && built[hi].is_none() {
                return Err(ERR_CORRUPT); // a transformed hmtx needs the transformed glyf of the same font
            }
        }
    }
    let table = |i: usize| -> R<&[u8]> {
        match &built[i] {
            Some(v) => Ok(&v[..]),
            None => plain(&stream, &entries[i]),
        }
    };

    if flavor != TAG_TTCF {
        let ids: Vec<usize> = (0..num_tables).collect();
        let mut out = Out::with_capacity(12 + 16 * num_tables, max)?;
        write_font(&mut out, flavor, &ids, &entries, &table)?;
        fix_head_checksum(&mut out.v, 0, num_tables)?;
        return Ok(out.v);
    }

    // a collection: TTC header, every font's directory, then every table once
    let n = fonts.len();
    let header = 12 + 4 * n + if ttc_version >= 0x0002_0000 { 12 } else { 0 };
    let dirs: usize = fonts.iter().map(|(_, idx)| 12 + 16 * idx.len()).sum();
    let mut out = Out::with_capacity(header + dirs, max)?;
    out.u32(TAG_TTCF)?;
    out.u32(if ttc_version >= 0x0002_0000 { 0x0002_0000 } else { 0x0001_0000 })?;
    out.u32(n as u32)?;
    let mut off = header;
    for (_, idx) in fonts.iter() {
        out.u32(off as u32)?;
        off += 12 + 16 * idx.len();
    }
    if ttc_version >= 0x0002_0000 {
        out.put(&[0u8; 12])?; // no DSIG
    }
    // table offsets first (shared), then the directories that point at them
    let mut table_off = vec![0u32; num_tables];
    let mut data = Out::with_capacity(0, max)?;
    let base = header + dirs;
    for i in 0..num_tables {
        if !fonts.iter().any(|(_, idx)| idx.contains(&i)) {
            continue;
        }
        table_off[i] = (base + data.v.len()) as u32;
        data.put(table(i)?)?;
        data.pad4()?;
    }
    for (fl, idx) in fonts.iter() {
        write_directory(&mut out, *fl, idx, &entries, &table, &table_off)?;
    }
    out.put(&data.v)?;
    Ok(out.v)
}

fn plain<'a>(stream: &'a [u8], e: &Entry) -> R<&'a [u8]> {
    if e.transformed {
        return Err(ERR_CORRUPT);
    }
    stream.get(e.src_off..e.src_off + e.orig_len as usize).ok_or(ERR_CORRUPT)
}

/// Exactly `n` bytes out of a Brotli stream: more or fewer is an error, and nothing past `n` is ever produced.
fn brotli_exact(comp: &[u8], n: usize) -> R<Vec<u8>> {
    let mut out = Vec::new();
    out.try_reserve_exact(n).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
    out.resize(n, 0);
    let mut dec = brotli_decompressor::Decompressor::new(comp, 4096);
    let mut got = 0;
    while got < n {
        match dec.read(&mut out[got..]) {
            Ok(0) => return Err(ERR_CORRUPT),
            Ok(k) => got += k,
            Err(_) => return Err(ERR_CORRUPT),
        }
    }
    let mut one = [0u8; 1];
    match dec.read(&mut one) {
        Ok(0) => Ok(out),
        _ => Err(ERR_CORRUPT), // the stream holds more than the directory says
    }
}

fn checksum(d: &[u8]) -> u32 {
    let mut s: u32 = 0;
    let mut chunks = d.chunks(4);
    for c in &mut chunks {
        let mut w = [0u8; 4];
        w[..c.len()].copy_from_slice(c);
        s = s.wrapping_add(u32::from_be_bytes(w));
    }
    s
}

fn write_font<'a>(out: &mut Out, flavor: u32, ids: &[usize], entries: &[Entry], table: &dyn Fn(usize) -> R<&'a [u8]>) -> R<()> {
    let n = ids.len();
    let dir_end = 12 + 16 * n;
    // offsets of every table after the directory
    let mut offs = vec![0u32; entries.len()];
    let mut pos = dir_end;
    for &i in ids {
        offs[i] = pos as u32;
        let len = table(i)?.len();
        pos = pos.checked_add((len + 3) & !3).ok_or(ERR_TOO_MUCH_MEMORY)?;
        if pos > out.max {
            return Err(ERR_TOO_MUCH_MEMORY);
        }
    }
    write_directory(out, flavor, ids, entries, table, &offs)?;
    out.reserve(pos - dir_end)?;
    for &i in ids {
        out.put(table(i)?)?;
        out.pad4()?;
    }
    Ok(())
}

fn write_directory<'a>(out: &mut Out, flavor: u32, ids: &[usize], entries: &[Entry], table: &dyn Fn(usize) -> R<&'a [u8]>, offs: &[u32]) -> R<()> {
    let n = ids.len();
    let mut tags: Vec<u32> = ids.iter().map(|&i| entries[i].tag).collect();
    tags.sort_unstable();
    if tags.windows(2).any(|w| w[0] == w[1]) {
        return Err(ERR_CORRUPT); // one font, one table per tag
    }
    let mut sel = 0u16;
    while (1usize << (sel + 1)) <= n {
        sel += 1;
    }
    let range = (1u32 << sel) * 16;
    out.u32(flavor)?;
    out.u16(n as u16)?;
    out.u16(range as u16)?;
    out.u16(sel)?;
    out.u16((n as u32 * 16 - range) as u16)?;
    let mut order: Vec<usize> = ids.to_vec();
    order.sort_by_key(|&i| entries[i].tag);
    for i in order {
        let t = table(i)?;
        out.u32(entries[i].tag)?;
        let sum = if entries[i].tag == TAG_HEAD && t.len() >= 12 {
            // the checksum of head is computed with checkSumAdjustment as 0
            let mut c = t.to_vec();
            c[8..12].copy_from_slice(&[0, 0, 0, 0]);
            checksum(&c)
        } else {
            checksum(t)
        };
        out.u32(sum)?;
        out.u32(offs[i])?;
        out.u32(t.len() as u32)?;
    }
    Ok(())
}

/// head.checkSumAdjustment of a single font: 0xB1B0AFBA minus the checksum of the whole file.
fn fix_head_checksum(font: &mut [u8], dir: usize, n: usize) -> R<()> {
    for k in 0..n {
        let rec = dir + 12 + 16 * k;
        let tag = u32::from_be_bytes(font[rec..rec + 4].try_into().unwrap());
        if tag == TAG_HEAD {
            let off = u32::from_be_bytes(font[rec + 8..rec + 12].try_into().unwrap()) as usize;
            let len = u32::from_be_bytes(font[rec + 12..rec + 16].try_into().unwrap()) as usize;
            if len < 12 || off + 12 > font.len() {
                return Err(ERR_CORRUPT);
            }
            font[off + 8..off + 12].copy_from_slice(&[0, 0, 0, 0]);
            let adj = 0xB1B0_AFBAu32.wrapping_sub(checksum(font));
            font[off + 8..off + 12].copy_from_slice(&adj.to_be_bytes());
        }
    }
    Ok(())
}

////////////////////////////////
// glyf / loca (§5.1)

const ARG_1_AND_2_ARE_WORDS: u16 = 0x0001;
const WE_HAVE_A_SCALE: u16 = 0x0008;
const MORE_COMPONENTS: u16 = 0x0020;
const WE_HAVE_AN_X_AND_Y_SCALE: u16 = 0x0040;
const WE_HAVE_A_TWO_BY_TWO: u16 = 0x0080;
const WE_HAVE_INSTRUCTIONS: u16 = 0x0100;

/// Rebuilds glyf and loca; also returns each glyph's xMin (what a transformed hmtx leaves out).
fn rebuild_glyf(src: &[u8], head: &[u8], max: usize) -> R<(Vec<u8>, Vec<u8>, Vec<i16>)> {
    let mut h = Buf::new(src);
    let _reserved = h.u16()?;
    let option_flags = h.u16()?;
    let num_glyphs = h.u16()? as usize;
    let index_format = h.u16()?;
    let sizes = [h.u32()?, h.u32()?, h.u32()?, h.u32()?, h.u32()?, h.u32()?, h.u32()?];
    if index_format > 1 || head.len() < 54 {
        return Err(ERR_CORRUPT);
    }
    // the font's own head must agree on the loca format the reader will use
    if u16::from_be_bytes([head[50], head[51]]) != index_format {
        return Err(ERR_CORRUPT);
    }
    let mut streams: [Buf; 7] = [Buf::new(&[]), Buf::new(&[]), Buf::new(&[]), Buf::new(&[]), Buf::new(&[]), Buf::new(&[]), Buf::new(&[])];
    for (k, &sz) in sizes.iter().enumerate() {
        streams[k] = Buf::new(h.bytes(sz as usize)?);
    }
    let overlap = if option_flags & 1 != 0 { Some(h.bytes((num_glyphs + 7) / 8)?) } else { None };
    let [mut n_contour, mut n_points, mut flags_s, mut glyph_s, mut composite_s, mut bbox_s, mut instr_s] = streams;
    let bitmap_len = 4 * ((num_glyphs + 31) / 32);
    let bbox_bitmap = bbox_s.bytes(bitmap_len)?;
    let has_bbox = |i: usize| bbox_bitmap[i >> 3] & (0x80 >> (i & 7)) != 0;

    let mut glyf = Out::with_capacity(0, max)?;
    let mut offsets: Vec<u32> = Vec::new();
    offsets.try_reserve_exact(num_glyphs + 1).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
    let mut x_mins: Vec<i16> = Vec::new();
    x_mins.try_reserve_exact(num_glyphs).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
    let mut end_pts: Vec<u16> = Vec::new();
    let mut pts: Vec<(i32, i32, bool)> = Vec::new();

    for gi in 0..num_glyphs {
        offsets.push(glyf.v.len() as u32);
        let nc = n_contour.i16()?;
        if nc == 0 {
            if has_bbox(gi) {
                return Err(ERR_CORRUPT); // an empty glyph has no box
            }
            x_mins.push(0);
            continue;
        }
        if nc < 0 {
            if nc != -1 || !has_bbox(gi) {
                return Err(ERR_CORRUPT); // composites carry their box explicitly
            }
            // the components, as they are in a glyf table
            let start = composite_s.p;
            let mut have_instr = false;
            loop {
                let fl = composite_s.u16()?;
                let _glyph = composite_s.u16()?;
                let mut n = if fl & ARG_1_AND_2_ARE_WORDS != 0 { 4 } else { 2 };
                if fl & WE_HAVE_A_SCALE != 0 {
                    n += 2;
                } else if fl & WE_HAVE_AN_X_AND_Y_SCALE != 0 {
                    n += 4;
                } else if fl & WE_HAVE_A_TWO_BY_TWO != 0 {
                    n += 8;
                }
                composite_s.bytes(n)?;
                if fl & WE_HAVE_INSTRUCTIONS != 0 {
                    have_instr = true;
                }
                if fl & MORE_COMPONENTS == 0 {
                    break;
                }
            }
            let comps = &composite_s.d[start..composite_s.p];
            let bbox = bbox_s.bytes(8)?;
            glyf.u16(0xFFFF)?;
            glyf.put(bbox)?;
            x_mins.push(i16::from_be_bytes([bbox[0], bbox[1]]));
            glyf.put(comps)?;
            if have_instr {
                let len = glyph_s.u255()?;
                glyf.u16(len)?;
                glyf.put(instr_s.bytes(len as usize)?)?;
            }
            glyf.pad4()?;
            continue;
        }
        // a simple glyph
        let nc = nc as usize;
        end_pts.clear();
        let mut total: u32 = 0;
        for _ in 0..nc {
            let np = n_points.u255()? as u32;
            total += np;
            if total == 0 || total > 0xFFFF {
                return Err(ERR_CORRUPT);
            }
            end_pts.push((total - 1) as u16);
        }
        pts.clear();
        pts.try_reserve(total as usize).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
        let (mut x, mut y) = (0i32, 0i32);
        for _ in 0..total {
            let fb = flags_s.u8()?;
            let on = fb & 0x80 == 0;
            let f = (fb & 0x7F) as u32;
            let n = if f < 84 { 1 } else if f < 120 { 2 } else if f < 124 { 3 } else { 4 };
            let d = glyph_s.bytes(n)?;
            let sign = |flag: u32, v: i32| if flag & 1 != 0 { v } else { -v };
            let (dx, dy) = if f < 10 {
                (0, sign(f, (((f & 14) << 7) + d[0] as u32) as i32))
            } else if f < 20 {
                (sign(f, ((((f - 10) & 14) << 7) + d[0] as u32) as i32), 0)
            } else if f < 84 {
                let b0 = f - 20;
                let b1 = d[0] as u32;
                (sign(f, (1 + (b0 & 0x30) + (b1 >> 4)) as i32), sign(f >> 1, (1 + ((b0 & 0x0C) << 2) + (b1 & 0x0F)) as i32))
            } else if f < 120 {
                let b0 = f - 84;
                (sign(f, (1 + ((b0 / 12) << 8) + d[0] as u32) as i32), sign(f >> 1, (1 + (((b0 % 12) >> 2) << 8) + d[1] as u32) as i32))
            } else if f < 124 {
                let b2 = d[1] as u32;
                (sign(f, ((d[0] as u32) << 4 | (b2 >> 4)) as i32), sign(f >> 1, (((b2 & 0x0F) << 8) + d[2] as u32) as i32))
            } else {
                (sign(f, ((d[0] as u32) << 8 | d[1] as u32) as i32), sign(f >> 1, ((d[2] as u32) << 8 | d[3] as u32) as i32))
            };
            x = x.checked_add(dx).ok_or(ERR_CORRUPT)?;
            y = y.checked_add(dy).ok_or(ERR_CORRUPT)?;
            if x < i16::MIN as i32 || x > i16::MAX as i32 || y < i16::MIN as i32 || y > i16::MAX as i32 {
                return Err(ERR_CORRUPT);
            }
            pts.push((x, y, on));
        }
        let ilen = glyph_s.u255()?;
        let instr = instr_s.bytes(ilen as usize)?;
        let bbox: [i16; 4] = if has_bbox(gi) {
            [bbox_s.i16()?, bbox_s.i16()?, bbox_s.i16()?, bbox_s.i16()?]
        } else {
            let mut b = [i16::MAX, i16::MAX, i16::MIN, i16::MIN];
            for &(px, py, _) in pts.iter() {
                b[0] = b[0].min(px as i16);
                b[1] = b[1].min(py as i16);
                b[2] = b[2].max(px as i16);
                b[3] = b[3].max(py as i16);
            }
            b
        };
        x_mins.push(bbox[0]);
        glyf.u16(nc as u16)?;
        for v in bbox {
            glyf.u16(v as u16)?;
        }
        for &e in end_pts.iter() {
            glyf.u16(e)?;
        }
        glyf.u16(ilen)?;
        glyf.put(instr)?;
        // flags, then x and y coordinates in their short / same forms
        let ov = overlap.map_or(false, |m| m[gi >> 3] & (0x80 >> (gi & 7)) != 0);
        let (mut lx, mut ly) = (0i32, 0i32);
        let (mut xs, mut ys) = (Vec::new(), Vec::new());
        xs.try_reserve(2 * pts.len()).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
        ys.try_reserve(2 * pts.len()).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
        glyf.reserve(pts.len())?;
        for (k, &(px, py, on)) in pts.iter().enumerate() {
            let mut fl: u8 = if on { 0x01 } else { 0 };
            if ov && k == 0 {
                fl |= 0x40;
            }
            let dx = px - lx;
            let dy = py - ly;
            if dx == 0 {
                fl |= 0x10;
            } else if dx > -256 && dx < 256 {
                fl |= 0x02 | if dx > 0 { 0x10 } else { 0 };
                xs.push(dx.unsigned_abs() as u8);
            } else {
                xs.extend_from_slice(&(dx as i16).to_be_bytes());
            }
            if dy == 0 {
                fl |= 0x20;
            } else if dy > -256 && dy < 256 {
                fl |= 0x04 | if dy > 0 { 0x20 } else { 0 };
                ys.push(dy.unsigned_abs() as u8);
            } else {
                ys.extend_from_slice(&(dy as i16).to_be_bytes());
            }
            glyf.u8(fl)?;
            lx = px;
            ly = py;
        }
        glyf.put(&xs)?;
        glyf.put(&ys)?;
        glyf.pad4()?;
    }
    offsets.push(glyf.v.len() as u32);

    let mut loca = Out::with_capacity((num_glyphs + 1) * if index_format == 0 { 2 } else { 4 }, max)?;
    for &o in offsets.iter() {
        if index_format == 0 {
            if o / 2 > 0xFFFF {
                return Err(ERR_CORRUPT); // too large for short offsets
            }
            loca.u16((o / 2) as u16)?;
        } else {
            loca.u32(o)?;
        }
    }
    Ok((glyf.v, loca.v, x_mins))
}

////////////////////////////////
// hmtx (§5.4)

fn rebuild_hmtx(src: &[u8], hhea: &[u8], x_mins: &[i16], orig_len: usize) -> R<Vec<u8>> {
    if hhea.len() < 36 {
        return Err(ERR_CORRUPT);
    }
    let n_hm = u16::from_be_bytes([hhea[34], hhea[35]]) as usize;
    let n_glyphs = x_mins.len();
    if n_hm == 0 || n_hm > n_glyphs {
        return Err(ERR_CORRUPT);
    }
    let mut b = Buf::new(src);
    let flags = b.u8()?;
    if flags & 0xFC != 0 || flags & 3 == 0 {
        return Err(ERR_CORRUPT);
    }
    let mut adv = Vec::new();
    adv.try_reserve_exact(n_hm).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
    for _ in 0..n_hm {
        adv.push(b.u16()?);
    }
    let mut lsb = Vec::new();
    lsb.try_reserve_exact(n_glyphs).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
    for i in 0..n_hm {
        lsb.push(if flags & 1 != 0 { x_mins[i] } else { b.i16()? });
    }
    for i in n_hm..n_glyphs {
        lsb.push(if flags & 2 != 0 { x_mins[i] } else { b.i16()? });
    }
    if b.left() != 0 {
        return Err(ERR_CORRUPT);
    }
    let size = 4 * n_hm + 2 * (n_glyphs - n_hm);
    if size != orig_len {
        return Err(ERR_CORRUPT);
    }
    let mut out = Out::with_capacity(size, size)?;
    for i in 0..n_hm {
        out.u16(adv[i])?;
        out.u16(lsb[i] as u16)?;
    }
    for i in n_hm..n_glyphs {
        out.u16(lsb[i] as u16)?;
    }
    Ok(out.v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base128() {
        assert_eq!(Buf::new(&[0x3F]).base128(), Ok(63));
        assert_eq!(Buf::new(&[0x81, 0x00]).base128(), Ok(128));
        assert_eq!(Buf::new(&[0x80, 0x01]).base128(), Err(ERR_CORRUPT)); // leading zero
        assert_eq!(Buf::new(&[0x8F, 0xFF, 0xFF, 0xFF, 0x7F]).base128(), Ok(0xFFFF_FFFF));
        assert_eq!(Buf::new(&[0x90, 0x80, 0x80, 0x80, 0x00]).base128(), Err(ERR_CORRUPT)); // overflow
        assert_eq!(Buf::new(&[0xFF, 0xFF, 0xFF, 0xFF, 0xFF]).base128(), Err(ERR_CORRUPT)); // too long
    }

    #[test]
    fn u255() {
        assert_eq!(Buf::new(&[252]).u255(), Ok(252));
        assert_eq!(Buf::new(&[255, 0]).u255(), Ok(253));
        assert_eq!(Buf::new(&[254, 0]).u255(), Ok(506));
        assert_eq!(Buf::new(&[253, 0x12, 0x34]).u255(), Ok(0x1234));
    }

    /// Outlines and advances of every glyph, as a font engine reads them.
    fn glyph_dump(font: &[u8]) -> (Vec<String>, Vec<u32>) {
        use skrifa::instance::{LocationRef, Size};
        use skrifa::outline::{DrawSettings, OutlinePen};
        use skrifa::raw::TableProvider;
        use skrifa::{FontRef, GlyphId, MetadataProvider, Tag};
        struct Pen(String);
        impl OutlinePen for Pen {
            fn move_to(&mut self, x: f32, y: f32) { self.0 += &format!("M{x},{y}"); }
            fn line_to(&mut self, x: f32, y: f32) { self.0 += &format!("L{x},{y}"); }
            fn quad_to(&mut self, a: f32, b: f32, x: f32, y: f32) { self.0 += &format!("Q{a},{b},{x},{y}"); }
            fn curve_to(&mut self, a: f32, b: f32, c: f32, d: f32, x: f32, y: f32) { self.0 += &format!("C{a},{b},{c},{d},{x},{y}"); }
            fn close(&mut self) { self.0 += "Z"; }
        }
        let f = FontRef::new(font).expect("parse");
        let outlines = f.outline_glyphs();
        let metrics = f.glyph_metrics(Size::unscaled(), LocationRef::default());
        let n = f.maxp().unwrap().num_glyphs() as u32;
        let mut dumps = Vec::new();
        for g in 0..n {
            let mut pen = Pen(String::new());
            if let Some(o) = outlines.get(GlyphId::new(g)) {
                o.draw(DrawSettings::unhinted(Size::unscaled(), LocationRef::default()), &mut pen).expect("draw");
            }
            dumps.push(format!("{pen}|{:?}", metrics.advance_width(GlyphId::new(g)), pen = pen.0));
        }
        let mut tags: Vec<u32> = f.table_directory.table_records().iter().map(|r| u32::from_be_bytes(r.tag().to_be_bytes())).collect();
        tags.sort();
        let _ = Tag::new(b"glyf");
        (dumps, tags)
    }

    fn fixture(name: &str) -> Vec<u8> {
        std::fs::read(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fonts").join(name)).expect(name)
    }

    /// Fonts as Google Fonts serves them, WOFF2 to Chrome and TrueType to older agents: same glyphs once decoded.
    #[test]
    fn real_fonts_match_their_truetype() {
        for name in ["firacode-var", "roboto", "notosansjp"] {
            let woff2 = fixture(&format!("{name}.woff2"));
            let ttf = fixture(&format!("{name}.ttf"));
            let sfnt = decode(&woff2, 32 << 20).unwrap_or_else(|e| panic!("{name}: error {e}"));
            let (a, ta) = glyph_dump(&sfnt);
            let (b, tb) = glyph_dump(&ttf);
            // the TrueType of a variable font is served as its default instance: no variation tables
            let fvar = u32::from_be_bytes(*b"fvar");
            if !ta.contains(&fvar) {
                assert_eq!(ta, tb, "{name}: tables");
            }
            assert_eq!(a.len(), b.len(), "{name}: glyph count");
            for (i, (x, y)) in a.iter().zip(b.iter()).enumerate() {
                assert_eq!(x, y, "{name}: glyph {i}");
            }
            // a limit below the font's size refuses it
            assert_eq!(decode(&woff2, 1024), Err(ERR_TOO_MUCH_MEMORY), "{name}: limit");
        }
    }

    /// A Brotli stream of stored (uncompressed) meta-blocks: enough to build WOFF2 files in tests.
    fn brotli_store(data: &[u8]) -> Vec<u8> {
        struct Bits { out: Vec<u8>, acc: u64, n: u32 }
        impl Bits {
            fn put(&mut self, v: u64, bits: u32) {
                self.acc |= v << self.n;
                self.n += bits;
                while self.n >= 8 { self.out.push(self.acc as u8); self.acc >>= 8; self.n -= 8; }
            }
            fn align(&mut self) { if self.n > 0 { self.put(0, 8 - self.n); } }
        }
        let mut b = Bits { out: Vec::new(), acc: 0, n: 0 };
        b.put(0, 1); // WBITS = 16
        for chunk in data.chunks(65536) {
            b.put(0, 1); // ISLAST = 0
            b.put(0, 2); // MNIBBLES = 4
            b.put((chunk.len() - 1) as u64, 16);
            b.put(1, 1); // ISUNCOMPRESSED
            b.align();
            b.out.extend_from_slice(chunk);
        }
        b.put(1, 1); // ISLAST
        b.put(1, 1); // ISLASTEMPTY
        b.align();
        b.out
    }

    fn base128_bytes(mut v: u32) -> Vec<u8> {
        let mut out = vec![(v & 0x7F) as u8];
        v >>= 7;
        while v > 0 { out.insert(0, 0x80 | (v & 0x7F) as u8); v >>= 7; }
        out
    }

    /// A WOFF2 of one font or of a collection, every table with its null transform (glyf / loca: version 3).
    fn woff2_of(fonts: &[&[u8]]) -> Vec<u8> {
        let rd16 = |d: &[u8], o: usize| u16::from_be_bytes([d[o], d[o + 1]]) as usize;
        let rd32 = |d: &[u8], o: usize| u32::from_be_bytes([d[o], d[o + 1], d[o + 2], d[o + 3]]);
        // unique tables (by content), and each font's list
        let mut tables: Vec<(u32, Vec<u8>)> = Vec::new();
        let mut per_font: Vec<(u32, Vec<usize>)> = Vec::new();
        for f in fonts {
            let n = rd16(f, 4);
            let mut idx = Vec::new();
            for k in 0..n {
                let r = 12 + 16 * k;
                let (tag, off, len) = (rd32(f, r), rd32(f, r + 8) as usize, rd32(f, r + 12) as usize);
                let data = f[off..off + len].to_vec();
                let i = tables.iter().position(|(t, d)| *t == tag && *d == data).unwrap_or_else(|| { tables.push((tag, data)); tables.len() - 1 });
                idx.push(i);
            }
            per_font.push((rd32(f, 0), idx));
        }
        let mut dir = Vec::new();
        let mut stream = Vec::new();
        for (tag, data) in tables.iter() {
            let tb = tag.to_be_bytes();
            let known = KNOWN_TAGS.iter().position(|k| **k == tb);
            let version: u8 = if *tag == TAG_GLYF || *tag == TAG_LOCA { 3 } else { 0 };
            match known {
                Some(i) => dir.push(i as u8 | version << 6),
                None => { dir.push(63 | version << 6); dir.extend_from_slice(&tb); }
            }
            dir.extend(base128_bytes(data.len() as u32));
            stream.extend_from_slice(data);
        }
        let collection = fonts.len() > 1;
        if collection {
            dir.extend_from_slice(&0x0001_0000u32.to_be_bytes());
            dir.push(fonts.len() as u8);
            for (fl, idx) in per_font.iter() {
                dir.push(idx.len() as u8);
                dir.extend_from_slice(&fl.to_be_bytes());
                for &i in idx { dir.push(i as u8); }
            }
        }
        let comp = brotli_store(&stream);
        let mut out = Vec::new();
        out.extend_from_slice(b"wOF2");
        out.extend_from_slice(&(if collection { TAG_TTCF } else { per_font[0].0 }).to_be_bytes());
        let total = 48 + dir.len() + comp.len();
        out.extend_from_slice(&(total as u32).to_be_bytes());
        out.extend_from_slice(&(tables.len() as u16).to_be_bytes());
        out.extend_from_slice(&[0, 0]);
        out.extend_from_slice(&((stream.len() + 1024) as u32).to_be_bytes());
        out.extend_from_slice(&(comp.len() as u32).to_be_bytes());
        out.extend_from_slice(&[0, 1, 0, 0]);
        out.extend_from_slice(&[0u8; 20]);
        out.extend_from_slice(&dir);
        out.extend_from_slice(&comp);
        out
    }

    #[test]
    fn null_transforms_and_collections() {
        let roboto = fixture("roboto.ttf");
        let jp = fixture("notosansjp.ttf");
        // one font, glyf and loca stored as they are
        let sfnt = decode(&woff2_of(&[&roboto]), 1 << 22).expect("single");
        assert_eq!(glyph_dump(&sfnt), glyph_dump(&roboto));
        // a collection of two fonts that share nothing, and of one font twice (every table shared)
        for pair in [[&roboto[..], &jp[..]], [&roboto[..], &roboto[..]]] {
            let ttc = decode(&woff2_of(&pair), 1 << 22).expect("collection");
            assert_eq!(&ttc[..4], b"ttcf");
            for (k, f) in pair.iter().enumerate() {
                let face = skrifa::FontRef::from_index(&ttc, k as u32).expect("face");
                let _ = face;
                let off = u32::from_be_bytes(ttc[12 + 4 * k..16 + 4 * k].try_into().unwrap()) as usize;
                // the face's tables, read through its directory, are the original ones
                let n = u16::from_be_bytes([ttc[off + 4], ttc[off + 5]]) as usize;
                for t in 0..n {
                    let r = off + 12 + 16 * t;
                    let tag = &ttc[r..r + 4];
                    let o = u32::from_be_bytes(ttc[r + 8..r + 12].try_into().unwrap()) as usize;
                    let l = u32::from_be_bytes(ttc[r + 12..r + 16].try_into().unwrap()) as usize;
                    let fn_ = u16::from_be_bytes([f[4], f[5]]) as usize;
                    let orig = (0..fn_).map(|q| 12 + 16 * q).find(|&q| &f[q..q + 4] == tag).expect("tag");
                    let (oo, ol) = (u32::from_be_bytes(f[orig + 8..orig + 12].try_into().unwrap()) as usize, u32::from_be_bytes(f[orig + 12..orig + 16].try_into().unwrap()) as usize);
                    assert_eq!(&ttc[o..o + l], &f[oo..oo + ol], "face {k} table {:?}", std::str::from_utf8(tag));
                }
            }
        }
        // the Brotli stream must hold exactly what the directory announces
        let s = brotli_store(b"abcdef");
        assert_eq!(brotli_exact(&s, 6).as_deref(), Ok(&b"abcdef"[..]));
        assert_eq!(brotli_exact(&s, 5), Err(ERR_CORRUPT));
        assert_eq!(brotli_exact(&s, 7), Err(ERR_CORRUPT));
    }

    /// Every truncation and many corruptions of a real font fail cleanly (no panic, no huge allocation).
    #[test]
    fn hostile_variants_of_a_real_font() {
        let woff2 = fixture("roboto.woff2");
        for cut in 0..woff2.len() {
            let _ = decode(&woff2[..cut], 1 << 20);
        }
        let mut seed: u32 = 0x1234_5678;
        for _ in 0..4000 {
            let mut v = woff2.clone();
            for _ in 0..4 {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                let i = seed as usize % v.len();
                v[i] = (seed >> 24) as u8;
            }
            let _ = decode(&v, 1 << 20);
        }
    }

    #[test]
    fn hostile_headers() {
        assert_eq!(decode(b"wOF2", 1 << 20), Err(ERR_CORRUPT));
        let mut h = vec![0u8; 48];
        h[..4].copy_from_slice(b"wOF2");
        h[8..12].copy_from_slice(&48u32.to_be_bytes());
        assert_eq!(decode(&h, 1 << 20), Err(ERR_CORRUPT)); // no tables
        h[12..14].copy_from_slice(&1u16.to_be_bytes());
        h[16..20].copy_from_slice(&u32::MAX.to_be_bytes());
        assert_eq!(decode(&h, 1 << 20), Err(ERR_TOO_MUCH_MEMORY)); // announced size over the limit
    }
}
