//! SVG documents as images, with resvg (usvg parses and simplifies, tiny-skia rasterises).
//!
//! The rules of an SVG shown as an image ("secure static mode" of SVG Integration): no script (resvg has none), no
//! external resource of any kind (images, fonts, style sheets: only data: URLs for <image>), no animation (the first
//! frame), no interaction. Fonts come from the system.
//!
//! Hostile documents are bounded before usvg builds anything: the encoded size (the caller), entity expansion of the
//! DTD (the "billion laughs" and its quadratic variant), the number of XML nodes, the nesting depth, and the number of
//! nodes `<use>` references and markers would instantiate (an exponential `<use>` chain); usvg's own tree is counted
//! again afterwards. Rendering is bounded by an estimate of the pixels it touches (every node's box, layers, filters),
//! scaled to the requested size, checked before drawing. Recursion depth (usvg and resvg recurse per nesting level and
//! per `<use>`) is bounded by the same depth limit, so the decoding thread's stack is enough.

use crate::{check_size, scale, Info, Limits, ERR_CORRUPT, ERR_TOO_COMPLEX, ERR_TOO_MUCH_MEMORY, ERR_UNSUPPORTED};
use resvg::tiny_skia::{PixmapMut, Transform};
use resvg::usvg::{self, fontdb, roxmltree, ImageHrefResolver, ImageKind, Node, Options, Tree};
use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock};

const SVG_NS: &str = "http://www.w3.org/2000/svg";
const XLINK_NS: &str = "http://www.w3.org/1999/xlink";

#[derive(Clone, Copy, Debug, PartialEq)]
struct Par {
    align: Option<(f32, f32)>,   // None = "none" (stretch)
    slice: bool,
}

pub struct Doc {
    tree: Tree,
    view_box: Option<[f32; 4]>,
    par: Par,
    size: (f32, f32),
    cost: f64,   // pixels touched when drawn at `size` (1 user unit = 1 pixel)
}

// The tree is shared by the decoding threads (rendered at several sizes at once).
const _: fn() = || {
    fn sync<T: Send + Sync>() {}
    sync::<Doc>();
};

static FONTS: OnceLock<Arc<fontdb::Database>> = OnceLock::new();
static NO_FONTS: OnceLock<Arc<fontdb::Database>> = OnceLock::new();

/// The system's fonts, loaded once (on the first document with text), shared by every document.
fn system_fonts() -> Arc<fontdb::Database> {
    FONTS
        .get_or_init(|| {
            let mut db = fontdb::Database::new();
            db.load_system_fonts();
            db.set_serif_family("Times New Roman");
            db.set_sans_serif_family("Arial");
            db.set_monospace_family("Consolas");
            db.set_cursive_family("Comic Sans MS");
            db.set_fantasy_family("Impact");
            Arc::new(db)
        })
        .clone()
}

thread_local! {
    static NESTED: Cell<u32> = const { Cell::new(0) };
}

////////////////////////////////
// Limits before parsing

/// Bytes the document's internal entities expand to; refused past `max`.
fn check_entities(text: &str, max: u64) -> Result<(), i32> {
    let Some(dt) = text.find("<!DOCTYPE") else { return Ok(()) };
    let rest = &text[dt..];
    let Some(open) = rest.find('[') else { return Ok(()) };
    let gt = rest.find('>').unwrap_or(rest.len());
    if gt < open {
        return Ok(());   // no internal subset
    }
    let subset_start = dt + open + 1;
    let Some(close) = text[subset_start..].find("]") else { return Err(ERR_CORRUPT) };
    let subset = &text[subset_start..subset_start + close];
    let body = &text[subset_start + close..];
    let mut decls: HashMap<&str, &str> = HashMap::new();
    let mut s = subset;
    while let Some(i) = s.find("<!ENTITY") {
        s = s[i + 8..].trim_start();
        if let Some(r) = s.strip_prefix('%') {
            s = r.trim_start();
        }
        let name_end = s.find(|c: char| c.is_whitespace()).unwrap_or(s.len());
        let name = &s[..name_end];
        s = s[name_end..].trim_start();
        let value = match s.chars().next() {
            Some(q @ ('"' | '\'')) => {
                let end = s[1..].find(q).ok_or(ERR_CORRUPT)?;
                let v = &s[1..1 + end];
                s = &s[1 + end + 1..];
                v
            }
            _ => "",   // external: not loaded
        };
        decls.entry(name).or_insert(value);
    }
    if decls.is_empty() {
        return Ok(());
    }
    fn expanded<'a>(name: &'a str, decls: &HashMap<&'a str, &'a str>, memo: &mut HashMap<&'a str, u64>, depth: u32) -> u64 {
        if let Some(&n) = memo.get(name) {
            return n;
        }
        if depth > 16 {
            return u64::MAX / 4;
        }
        let Some(v) = decls.get(name) else { return name.len() as u64 + 2 };
        let n = refs(v, decls, memo, depth + 1);
        memo.insert(name, n);
        n
    }
    fn refs<'a>(v: &'a str, decls: &HashMap<&'a str, &'a str>, memo: &mut HashMap<&'a str, u64>, depth: u32) -> u64 {
        let mut total = 0u64;
        let mut t = v;
        while let Some(i) = t.find('&') {
            total = total.saturating_add(i as u64);
            t = &t[i + 1..];
            match t.find(';') {
                Some(j) if j < 256 && !t[..j].starts_with('#') => {
                    let name = &t[..j];
                    total = total.saturating_add(if decls.contains_key(name) { expanded(name, decls, memo, depth) } else { j as u64 + 2 });
                    t = &t[j + 1..];
                }
                _ => total = total.saturating_add(1),
            }
        }
        total.saturating_add(t.len() as u64)
    }
    let mut memo = HashMap::new();
    if refs(body, &decls, &mut memo, 0) > max.saturating_add(body.len() as u64) {
        return Err(ERR_TOO_COMPLEX);
    }
    Ok(())
}

/// Nesting depth of the raw markup, before any parser builds anything (a bound for everything after it).
fn scan_depth(text: &str, max: u32) -> Result<(), i32> {
    let b = text.as_bytes();
    let find = |from: usize, pat: &[u8]| -> usize {
        b[from.min(b.len())..].windows(pat.len()).position(|w| w == pat).map(|p| from + p + pat.len()).unwrap_or(b.len())
    };
    let mut i = 0;
    let mut depth = 0u32;
    while i < b.len() {
        let Some(p) = b[i..].iter().position(|&c| c == b'<') else { break };
        let at = i + p;
        let rest = &b[at..];
        if rest.starts_with(b"<!--") {
            i = find(at + 4, b"-->");
        } else if rest.starts_with(b"<![CDATA[") {
            i = find(at + 9, b"]]>");
        } else if rest.starts_with(b"<?") {
            i = find(at + 2, b"?>");
        } else if rest.starts_with(b"<!") {
            let gt = find(at, b">");
            let open = find(at, b"[");
            i = if open < gt { find(open, b"]") } else { gt };
        } else if rest.starts_with(b"</") {
            depth = depth.saturating_sub(1);
            i = find(at, b">");
        } else {
            // a start tag: to its '>' outside quoted attribute values
            let mut j = at + 1;
            let mut quote = 0u8;
            while j < b.len() {
                let c = b[j];
                if quote != 0 {
                    if c == quote {
                        quote = 0;
                    }
                } else if c == b'"' || c == b'\'' {
                    quote = c;
                } else if c == b'>' {
                    break;
                }
                j += 1;
            }
            if j >= b.len() || b[j - 1] != b'/' {
                depth += 1;
                if depth > max {
                    return Err(ERR_TOO_COMPLEX);
                }
            }
            i = j + 1;
        }
    }
    Ok(())
}

/// Depth of the element tree, without recursion.
fn check_depth(doc: &roxmltree::Document, max: u32) -> Result<(), i32> {
    let mut stack = vec![(doc.root(), 0u32)];
    while let Some((n, d)) = stack.pop() {
        if d > max {
            return Err(ERR_TOO_COMPLEX);
        }
        for c in n.children().filter(|c| c.is_element()) {
            stack.push((c, d + 1));
        }
    }
    Ok(())
}

fn href<'a>(n: roxmltree::Node<'a, 'a>) -> Option<&'a str> {
    n.attribute((XLINK_NS, "href")).or_else(|| n.attribute("href"))
}

fn url_id(v: &str) -> Option<&str> {
    let v = v.trim();
    let inner = v.strip_prefix("url(")?.split(')').next()?.trim().trim_matches(|c| c == '"' || c == '\'');
    inner.strip_prefix('#')
}

/// Nodes the document instantiates once `<use>` references and markers are expanded (saturating).
fn check_expansion(doc: &roxmltree::Document, l: &Limits) -> Result<(), i32> {
    let mut ids: HashMap<&str, roxmltree::NodeId> = HashMap::new();
    for n in doc.descendants().filter(|n| n.is_element()) {
        if let Some(id) = n.attribute("id") {
            ids.entry(id).or_insert(n.id());
        }
    }
    struct Walk<'a, 'i> {
        doc: &'a roxmltree::Document<'i>,
        ids: HashMap<&'a str, roxmltree::NodeId>,
        memo: HashMap<roxmltree::NodeId, u64>,
        visiting: HashSet<roxmltree::NodeId>,
        max_depth: u32,
        failed: bool,
    }
    impl<'a, 'i> Walk<'a, 'i> {
        fn size(&mut self, id: roxmltree::NodeId, depth: u32) -> u64 {
            if let Some(&n) = self.memo.get(&id) {
                return n;
            }
            if depth > self.max_depth {
                self.failed = true;
                return u64::MAX / 4;
            }
            if !self.visiting.insert(id) {
                return 0;   // a cycle: usvg skips it
            }
            let node = self.doc.get_node(id).unwrap();
            let mut total = 1u64;
            for c in node.children().filter(|c| c.is_element()) {
                total = total.saturating_add(self.size(c.id(), depth + 1));
            }
            let tag = node.tag_name().name();
            if tag == "use" {
                if let Some(t) = href(node).and_then(|h| h.strip_prefix('#')).and_then(|h| self.ids.get(h).copied()) {
                    total = total.saturating_add(self.size(t, depth + 1));
                }
            }
            if matches!(tag, "path" | "line" | "polyline" | "polygon") {
                let mut markers = 0u64;
                for a in ["marker-start", "marker-mid", "marker-end"] {
                    if let Some(m) = node.attribute(a).and_then(url_id).and_then(|m| self.ids.get(m).copied()) {
                        markers = markers.saturating_add(self.size(m, depth + 1));
                    }
                }
                if node.attribute("style").map(|s| s.contains("marker")).unwrap_or(false) {
                    markers = markers.saturating_add(64);
                }
                if markers > 0 {
                    let pts = node.attribute("d").or_else(|| node.attribute("points")).unwrap_or("");
                    let vertices = pts.bytes().filter(|b| b.is_ascii_alphabetic() || *b == b',' || *b == b' ').count() as u64 / 2 + 2;
                    total = total.saturating_add(markers.saturating_mul(vertices));
                }
            }
            self.visiting.remove(&id);
            self.memo.insert(id, total);
            total
        }
    }
    let mut w = Walk { doc, ids, memo: HashMap::new(), visiting: HashSet::new(), max_depth: l.svg_max_depth, failed: false };
    let n = w.size(doc.root().id(), 0);
    if w.failed || n > l.svg_max_nodes as u64 {
        return Err(ERR_TOO_COMPLEX);
    }
    Ok(())
}

////////////////////////////////
// Natural size

fn parse_length(v: &str) -> Option<f32> {
    let v = v.trim();
    let end = v.find(|c: char| !(c.is_ascii_digit() || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E')).unwrap_or(v.len());
    // "1e" would swallow the unit "em": back off an exponent that has no digits after it
    let (num, unit) = if end > 0 && v[..end].ends_with(['e', 'E']) { (&v[..end - 1], &v[end - 1..]) } else { (&v[..end], &v[end..]) };
    let n: f32 = num.parse().ok()?;
    let k = match unit.trim().to_ascii_lowercase().as_str() {
        "" | "px" => 1.0,
        "pt" => 4.0 / 3.0,
        "pc" => 16.0,
        "in" => 96.0,
        "cm" => 96.0 / 2.54,
        "mm" => 96.0 / 25.4,
        "q" => 96.0 / 101.6,
        "em" => 16.0,
        "ex" => 8.0,
        _ => return None,   // percentages, auto: no natural size
    };
    let px = n * k;
    (px.is_finite() && px >= 0.0).then_some(px)
}

fn parse_view_box(v: &str) -> Option<[f32; 4]> {
    let mut it = v.split(|c: char| c.is_whitespace() || c == ',').filter(|s| !s.is_empty()).map(|s| s.parse::<f32>());
    let b = [it.next()?.ok()?, it.next()?.ok()?, it.next()?.ok()?, it.next()?.ok()?];
    (b[2] > 0.0 && b[3] > 0.0 && b.iter().all(|x| x.is_finite())).then_some(b)
}

fn parse_par(v: Option<&str>) -> Par {
    let mut par = Par { align: Some((0.5, 0.5)), slice: false };
    let Some(v) = v else { return par };
    for w in v.split_whitespace() {
        match w {
            "defer" => {}
            "none" => par.align = None,
            "meet" => par.slice = false,
            "slice" => par.slice = true,
            a if a.len() == 8 && a.starts_with('x') => {
                let f = |s: &str| match s {
                    "Min" => 0.0,
                    "Max" => 1.0,
                    _ => 0.5,
                };
                par.align = Some((f(&a[1..4]), f(&a[5..8])));
            }
            _ => {}
        }
    }
    par
}

/// The transform that fits `vb` into a `w` x `h` viewport.
fn fit(vb: [f32; 4], par: Par, w: f32, h: f32) -> Transform {
    let (sx, sy) = (w / vb[2], h / vb[3]);
    match par.align {
        None => Transform::from_row(sx, 0.0, 0.0, sy, -vb[0] * sx, -vb[1] * sy),
        Some((ax, ay)) => {
            let s = if par.slice { sx.max(sy) } else { sx.min(sy) };
            let tx = -vb[0] * s + ax * (w - vb[2] * s);
            let ty = -vb[1] * s + ay * (h - vb[3] * s);
            Transform::from_row(s, 0.0, 0.0, s, tx, ty)
        }
    }
}

////////////////////////////////
// Embedded images: data: URLs only, sizes checked from their headers

fn raster_size(d: &[u8]) -> Option<(u64, u64)> {
    let be32 = |i: usize| u32::from_be_bytes([d[i], d[i + 1], d[i + 2], d[i + 3]]) as u64;
    let le16 = |i: usize| u16::from_le_bytes([d[i], d[i + 1]]) as u64;
    if d.len() >= 24 && d.starts_with(b"\x89PNG") {
        return Some((be32(16), be32(20)));
    }
    if d.len() >= 10 && d.starts_with(b"GIF8") {
        return Some((le16(6), le16(8)));
    }
    if d.len() >= 30 && d.starts_with(b"RIFF") && &d[8..12] == b"WEBP" {
        let le24 = |i: usize| d[i] as u64 | (d[i + 1] as u64) << 8 | (d[i + 2] as u64) << 16;
        return match &d[12..16] {
            b"VP8 " => Some((le16(26) & 0x3FFF, le16(28) & 0x3FFF)),
            b"VP8L" => {
                let b = u32::from_le_bytes([d[21], d[22], d[23], d[24]]) as u64;
                Some(((b & 0x3FFF) + 1, ((b >> 14) & 0x3FFF) + 1))
            }
            b"VP8X" => Some((le24(24) + 1, le24(27) + 1)),
            _ => None,
        };
    }
    if d.len() >= 4 && d.starts_with(&[0xFF, 0xD8]) {
        let mut i = 2;
        while i + 9 < d.len() {
            if d[i] != 0xFF {
                return None;
            }
            let m = d[i + 1];
            if m == 0xFF {
                i += 1;
                continue;
            }
            if m == 0xD8 || m == 0x01 || (0xD0..=0xD7).contains(&m) {
                i += 2;
                continue;
            }
            let n = ((d[i + 2] as usize) << 8) | d[i + 3] as usize;
            if (0xC0..=0xCF).contains(&m) && m != 0xC4 && m != 0xC8 && m != 0xCC {
                let h = ((d[i + 5] as u64) << 8) | d[i + 6] as u64;
                let w = ((d[i + 7] as u64) << 8) | d[i + 8] as u64;
                return Some((w, h));
            }
            if n < 2 {
                return None;
            }
            i += 2 + n;
        }
    }
    None
}

fn options(l: Limits, text: bool) -> Options<'static> {
    let mut o = Options::default();
    o.font_size = 16.0;   // CSS "medium"
    o.fontdb = if text { system_fonts() } else { NO_FONTS.get_or_init(|| Arc::new(fontdb::Database::new())).clone() };
    o.image_href_resolver = ImageHrefResolver {
        resolve_data: Box::new(move |mime: &str, data: Arc<Vec<u8>>, _opts: &Options| {
            if l.svg_data_images == 0 {
                return None;
            }
            if let Some((w, h)) = raster_size(&data) {
                check_size(w, h, &l).ok()?;
                return Some(match &data[..4] {
                    [0x89, b'P', ..] => ImageKind::PNG(data),
                    [b'G', b'I', ..] => ImageKind::GIF(data),
                    [b'R', b'I', ..] => ImageKind::WEBP(data),
                    _ => ImageKind::JPEG(data),
                });
            }
            let is_svg = mime == "image/svg+xml" || data.iter().take(512).any(|&b| b == b'<');
            if !is_svg || NESTED.with(|n| n.get()) > 0 {
                return None;   // one level of SVG in SVG, as an image of an image
            }
            NESTED.with(|n| n.set(n.get() + 1));
            let r = std::str::from_utf8(&data).ok().and_then(|t| build(t, &l).ok()).map(|(t, _)| ImageKind::SVG(t));
            NESTED.with(|n| n.set(n.get() - 1));
            r
        }),
        // anything that is not a data: URL is an external resource: never loaded in an image
        resolve_string: Box::new(|_, _| None),
    };
    o
}

/// Every check, then usvg's tree, and the root element (for the natural size).
fn build(text: &str, l: &Limits) -> Result<(Tree, RootAttrs), i32> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    check_entities(text, l.svg_max_expansion)?;
    scan_depth(text, l.svg_max_depth)?;
    let xml_opt = roxmltree::ParsingOptions { allow_dtd: true, nodes_limit: l.svg_max_nodes.max(1), ..Default::default() };
    let doc = roxmltree::Document::parse_with_options(text, xml_opt).map_err(|e| match e {
        roxmltree::Error::NodesLimitReached | roxmltree::Error::EntityReferenceLoop(_) => ERR_TOO_COMPLEX,
        _ => ERR_CORRUPT,
    })?;
    check_depth(&doc, l.svg_max_depth)?;
    let root = doc.root_element();
    if root.tag_name().name() != "svg" || root.tag_name().namespace() != Some(SVG_NS) {
        return Err(ERR_CORRUPT);   // not an SVG document (an <svg> outside the SVG namespace is not one either)
    }
    check_expansion(&doc, l)?;
    let attrs = RootAttrs {
        width: root.attribute("width").and_then(parse_length),
        height: root.attribute("height").and_then(parse_length),
        view_box: root.attribute("viewBox").and_then(parse_view_box),
        par: parse_par(root.attribute("preserveAspectRatio")),
    };
    let has_text = l.svg_text != 0 && doc.descendants().any(|n| n.is_element() && matches!(n.tag_name().name(), "text" | "textPath" | "tspan"));
    let opt = options(*l, has_text);
    let tree = Tree::from_xmltree(&doc, &opt).map_err(|e| match e {
        usvg::Error::ElementsLimitReached => ERR_TOO_COMPLEX,
        _ => ERR_CORRUPT,
    })?;
    Ok((tree, attrs))
}

struct RootAttrs {
    width: Option<f32>,
    height: Option<f32>,
    view_box: Option<[f32; 4]>,
    par: Par,
}

////////////////////////////////
// Cost

fn area(r: Option<usvg::Rect>, canvas: (f32, f32)) -> f64 {
    let Some(r) = r else { return 0.0 };
    let x0 = r.left().max(0.0);
    let y0 = r.top().max(0.0);
    let x1 = r.right().min(canvas.0);
    let y1 = r.bottom().min(canvas.1);
    if x1 <= x0 || y1 <= y0 {
        return 0.0;
    }
    ((x1 - x0) as f64) * ((y1 - y0) as f64)
}

/// Pixels touched drawing the tree at its own size, and its node count. Iterative (the tree may be deep).
fn cost(tree: &Tree) -> (f64, u64) {
    let canvas = (tree.size().width(), tree.size().height());
    let mut total = 0f64;
    let mut nodes = 0u64;
    let mut stack: Vec<&usvg::Group> = vec![tree.root()];
    let mut extra: Vec<&usvg::Group> = Vec::new();
    while let Some(g) = stack.pop() {
        nodes += 1;
        let layer = !g.filters().is_empty() || g.clip_path().is_some() || g.mask().is_some() || g.opacity().get() < 1.0 || g.isolate();
        if layer {
            total += area(Some(g.abs_layer_bounding_box().to_rect()), canvas);
        }
        for f in g.filters() {
            let region = area(Some(f.rect().to_rect().transform(g.abs_transform()).unwrap_or(f.rect().to_rect())), canvas);
            total += region * (f.primitives().len() as f64) * 4.0;
        }
        if let Some(c) = g.clip_path() {
            extra.push(c.root());
        }
        if let Some(m) = g.mask() {
            extra.push(m.root());
        }
        for n in g.children() {
            match n {
                Node::Group(c) => stack.push(c),
                Node::Path(p) => {
                    nodes += 1;
                    total += area(Some(p.abs_stroke_bounding_box()), canvas).max(area(Some(p.abs_bounding_box()), canvas));
                }
                Node::Image(i) => {
                    nodes += 1;
                    total += area(Some(i.abs_bounding_box()), canvas);
                    if let ImageKind::SVG(t) = i.kind() {
                        let (c, n) = cost(t);
                        total += c;
                        nodes += n;
                    }
                }
                Node::Text(t) => {
                    nodes += 1;
                    stack.push(t.flattened());
                }
            }
        }
        if stack.is_empty() {
            if let Some(e) = extra.pop() {
                stack.push(e);
            }
        }
    }
    (total + nodes as f64 * 64.0, nodes)
}

////////////////////////////////

pub fn parse(bytes: &[u8], l: &Limits, info: &mut Info) -> Result<Doc, i32> {
    if bytes.starts_with(&[0x1f, 0x8b]) {
        return Err(ERR_UNSUPPORTED);   // gzip without Content-Encoding: browsers refuse it too
    }
    let text = std::str::from_utf8(bytes).map_err(|_| ERR_CORRUPT)?;
    let (tree, a) = build(text, l)?;
    let (c, nodes) = cost(&tree);
    if nodes > l.svg_max_nodes as u64 {
        return Err(ERR_TOO_COMPLEX);
    }
    let size = (tree.size().width(), tree.size().height());
    *info = Info { frames: 1, plays: 1, has_alpha: 1, bit_depth: 8, ..Default::default() };
    let ratio = match (a.view_box, a.width, a.height) {
        (Some(vb), _, _) => vb[2] / vb[3],
        (None, Some(w), Some(h)) if w > 0.0 && h > 0.0 => w / h,
        _ => 0.0,
    };
    info.svg_ratio = ratio;
    if let Some(w) = a.width {
        info.svg_has_w = 1;
        info.svg_w = w;
    }
    if let Some(h) = a.height {
        info.svg_has_h = 1;
        info.svg_h = h;
    }
    // a size for whoever needs one (probes, scripts): the natural size, completed by the ratio, else 300 x 150
    let (w, h) = match (a.width, a.height) {
        (Some(w), Some(h)) => (w, h),
        (Some(w), None) if ratio > 0.0 => (w, w / ratio),
        (None, Some(h)) if ratio > 0.0 => (h * ratio, h),
        (None, None) if ratio > 0.0 => {
            if ratio >= 2.0 { (300.0, 300.0 / ratio) } else { (150.0 * ratio, 150.0) }
        }
        (Some(w), None) => (w, 150.0),
        (None, Some(h)) => (300.0, h),
        _ => (300.0, 150.0),
    };
    info.width = (w.ceil() as u32).max(1);
    info.height = (h.ceil() as u32).max(1);
    Ok(Doc { tree, view_box: a.view_box, par: a.par, size, cost: c })
}

pub fn render(d: &Doc, l: &Limits, w: u32, h: u32, out: &mut [u8]) -> Result<(), i32> {
    check_size(w as u64, h as u64, l)?;
    let (sw, sh) = d.size;
    let vb = d.view_box.unwrap_or([0.0, 0.0, sw, sh]);
    let par = if d.view_box.is_some() { d.par } else { Par { align: Some((0.5, 0.5)), slice: false } };
    let into_target = fit(vb, par, w as f32, h as f32);
    let from_size = fit(vb, par, sw, sh).invert().ok_or(ERR_CORRUPT)?;
    let ts = into_target.pre_concat(from_size);
    let k = (ts.sx.abs() as f64 * ts.sy.abs() as f64).max(ts.kx.abs() as f64 * ts.ky.abs() as f64).max(1e-6);
    if d.cost * k > l.svg_max_render_cost as f64 {
        return Err(ERR_TOO_COMPLEX);
    }
    out.fill(0);
    let mut pm = PixmapMut::from_bytes(out, w, h).ok_or(ERR_TOO_MUCH_MEMORY)?;
    resvg::render(&d.tree, ts, &mut pm);
    scale::unpremultiply(out);
    Ok(())
}
