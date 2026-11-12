//! Content-Encoding, decoded as the body streams in (what WinHTTP's decompression did, with Brotli on top). As with
//! WinHTTP, the head the host reads then has no Content-Encoding nor Content-Length (http.rs).
//!
//! Bounded: a few hundred bytes of Brotli can expand to gigabytes, so the decoder never produces more than one output
//! buffer (`OUT`) per step. The caller hands each step to the host (under back-pressure and `max_body`) before it asks
//! for the next one: what is in memory at any time is one input chunk and one output buffer, whatever the ratio.

use std::io::{self, BufRead, Read};

use brotli_decompressor::{BrotliDecompressStream, BrotliResult, BrotliState, StandardAlloc};

/// The most one step decodes.
pub(crate) const OUT: usize = 64 << 10;

/// The encoded bytes not decoded yet. The decoders read it as a non-blocking source: "would block" when it is empty
/// and more may come, end of file once the body ended.
#[derive(Default)]
struct Feed {
    buf: Vec<u8>,
    pos: usize,
    end: bool,
}

impl Feed {
    fn push(&mut self, input: &[u8]) {
        if self.pos == self.buf.len() {
            self.buf.clear();
            self.pos = 0;
        }
        self.buf.extend_from_slice(input);
    }

    fn pending(&self) -> &[u8] {
        &self.buf[self.pos..]
    }
}

impl Read for Feed {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let n = {
            let src = self.fill_buf()?;
            let n = src.len().min(out.len());
            out[..n].copy_from_slice(&src[..n]);
            n
        };
        self.consume(n);
        Ok(n)
    }
}

impl BufRead for Feed {
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        if self.pos < self.buf.len() {
            Ok(&self.buf[self.pos..])
        } else if self.end {
            Ok(&[])
        } else {
            Err(io::ErrorKind::WouldBlock.into())
        }
    }

    fn consume(&mut self, n: usize) {
        self.pos = (self.pos + n).min(self.buf.len());
        if self.pos == self.buf.len() {
            self.buf.clear();
            self.pos = 0;
        }
    }
}

/// Brotli through the decoder's stream interface: it says when it needs more output, so one step stops at `OUT`.
struct Brotli {
    state: BrotliState<StandardAlloc, StandardAlloc, StandardAlloc>,
    input: Feed,
    total_out: usize,
    finished: bool,
}

impl Brotli {
    fn new() -> Brotli {
        let mut state = BrotliState::new(StandardAlloc::default(), StandardAlloc::default(), StandardAlloc::default());
        // RFC 7932's window (16 MiB at most): the large-window extension would let a server make us allocate 1 GiB
        state.large_window = false;
        Brotli { state, input: Feed::default(), total_out: 0, finished: false }
    }
}

impl Read for Brotli {
    /// Ok(0): the stream ended. WouldBlock: it needs more input.
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let Brotli { state, input, total_out, finished } = self;
        if *finished { return Ok(0); }
        let src = &input.buf[input.pos..];
        let (mut avail_in, mut in_off) = (src.len(), 0usize);
        let (mut avail_out, mut out_off) = (out.len(), 0usize);
        let r = BrotliDecompressStream(&mut avail_in, &mut in_off, src, &mut avail_out, &mut out_off, out, total_out, state);
        input.consume(in_off);
        match r {
            BrotliResult::ResultSuccess => {
                *finished = true;
                Ok(out_off)
            }
            BrotliResult::NeedsMoreOutput if out_off > 0 => Ok(out_off),
            // (no output and no room asked for: would spin)
            BrotliResult::NeedsMoreOutput | BrotliResult::ResultFailure => Err(io::Error::new(io::ErrorKind::InvalidData, "corrupt brotli stream")),
            BrotliResult::NeedsMoreInput if out_off > 0 => Ok(out_off),
            BrotliResult::NeedsMoreInput if input.end => Err(io::Error::new(io::ErrorKind::UnexpectedEof, "truncated brotli stream")),
            BrotliResult::NeedsMoreInput => Err(io::ErrorKind::WouldBlock.into()),
        }
    }
}

enum Kind {
    Identity,
    /// "deflate": zlib as the standard says, or the raw stream some servers send (told by the first two bytes)
    Sniff(Feed),
    Gzip(Box<flate2::bufread::MultiGzDecoder<Feed>>),
    Zlib(Box<flate2::bufread::ZlibDecoder<Feed>>),
    Raw(Box<flate2::bufread::DeflateDecoder<Feed>>),
    Br(Box<Brotli>),
}

pub(crate) struct Decoder {
    kind: Kind,
    out: Vec<u8>,
    fed: u64,
    ended: bool,
    done: bool,
}

impl Decoder {
    /// The decoder for a Content-Encoding value; anything else (several codings, unknown ones) is passed through.
    pub fn new(encoding: Option<&str>) -> Decoder {
        let kind = match encoding.map(|e| e.trim().to_ascii_lowercase()).as_deref() {
            Some("gzip") | Some("x-gzip") => Kind::Gzip(Box::new(flate2::bufread::MultiGzDecoder::new(Feed::default()))),
            Some("deflate") => Kind::Sniff(Feed::default()),
            Some("br") => Kind::Br(Box::new(Brotli::new())),
            _ => Kind::Identity,
        };
        let out = if matches!(kind, Kind::Identity) { Vec::new() } else { vec![0; OUT] };
        Decoder { kind, out, fed: 0, ended: false, done: false }
    }

    pub fn is_identity(&self) -> bool {
        matches!(self.kind, Kind::Identity)
    }

    fn feed_mut(&mut self) -> Option<&mut Feed> {
        match &mut self.kind {
            Kind::Identity => None,
            Kind::Sniff(f) => Some(f),
            Kind::Gzip(d) => Some(d.get_mut()),
            Kind::Zlib(d) => Some(d.get_mut()),
            Kind::Raw(d) => Some(d.get_mut()),
            Kind::Br(b) => Some(&mut b.input),
        }
    }

    /// Hands encoded bytes over. Call `next` until it returns None before feeding more: the input is then held once.
    /// What comes after the end of the stream is dropped, as browsers do.
    pub fn feed(&mut self, input: &[u8]) {
        if self.done || input.is_empty() { return; }
        self.fed += input.len() as u64;
        if let Some(f) = self.feed_mut() { f.push(input); }
    }

    /// The body ended: `next` then gives what the decoder still holds, and a truncated stream is an error.
    pub fn end(&mut self) {
        self.ended = true;
        if let Some(f) = self.feed_mut() { f.end = true; }
    }

    /// The next decoded piece (at most `OUT` bytes), or None when the input given so far is used up (or the stream
    /// ended). After `end`, None means the whole body was decoded.
    pub fn next(&mut self) -> io::Result<Option<&[u8]>> {
        if self.done { return Ok(None); }
        // an empty body under a coding (a 304, a HEAD answered in full) is an empty body, not a broken stream
        if self.ended && self.fed == 0 {
            self.done = true;
            return Ok(None);
        }
        if let Kind::Sniff(f) = &mut self.kind {
            let head = f.pending();
            if head.len() < 2 {
                if !f.end { return Ok(None); }
                self.done = true;
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "truncated deflate stream"));
            }
            let (b0, b1) = (head[0] as u16, head[1] as u16);
            let zlib = b0 & 0x0F == 8 && (b0 << 8 | b1) % 31 == 0;
            let f = std::mem::take(f);
            self.kind = if zlib {
                Kind::Zlib(Box::new(flate2::bufread::ZlibDecoder::new(f)))
            } else {
                Kind::Raw(Box::new(flate2::bufread::DeflateDecoder::new(f)))
            };
        }
        let r = match &mut self.kind {
            Kind::Identity | Kind::Sniff(_) => return Ok(None),
            Kind::Gzip(d) => d.read(&mut self.out),
            Kind::Zlib(d) => d.read(&mut self.out),
            Kind::Raw(d) => d.read(&mut self.out),
            Kind::Br(b) => b.read(&mut self.out),
        };
        match r {
            Ok(0) => {
                self.done = true;
                // what followed the stream's end is not kept
                if let Some(f) = self.feed_mut() { *f = Feed { end: true, ..Feed::default() }; }
                Ok(None)
            }
            Ok(n) => Ok(Some(&self.out[..n])),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(e) => {
                self.done = true;
                Err(e)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::write::{DeflateEncoder, GzEncoder, ZlibEncoder};
    use flate2::Compression;
    use std::io::Write;

    fn drain(d: &mut Decoder, out: &mut Vec<u8>) -> io::Result<()> {
        while let Some(piece) = d.next()? {
            assert!(piece.len() <= OUT);
            out.extend_from_slice(piece);
        }
        Ok(())
    }

    fn roundtrip(mut d: Decoder, enc: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        for piece in enc.chunks(7) {
            d.feed(piece);
            drain(&mut d, &mut out).unwrap();
        }
        d.end();
        drain(&mut d, &mut out).unwrap();
        out
    }

    #[test]
    fn codings() {
        let text = "compressible ".repeat(5000).into_bytes();
        let mut g = GzEncoder::new(Vec::new(), Compression::default());
        g.write_all(&text).unwrap();
        assert_eq!(roundtrip(Decoder::new(Some("gzip")), &g.finish().unwrap()), text);
        let mut z = ZlibEncoder::new(Vec::new(), Compression::default());
        z.write_all(&text).unwrap();
        assert_eq!(roundtrip(Decoder::new(Some("Deflate")), &z.finish().unwrap()), text);
        let mut r = DeflateEncoder::new(Vec::new(), Compression::default());
        r.write_all(&text).unwrap();
        assert_eq!(roundtrip(Decoder::new(Some("deflate")), &r.finish().unwrap()), text);
        assert_eq!(roundtrip(Decoder::new(Some("gzip")), &[]), Vec::<u8>::new());
    }

    #[test]
    fn two_gzip_members() {
        let mut enc = Vec::new();
        for part in [b"first ".as_slice(), b"second".as_slice()] {
            let mut g = GzEncoder::new(Vec::new(), Compression::default());
            g.write_all(part).unwrap();
            enc.extend(g.finish().unwrap());
        }
        assert_eq!(roundtrip(Decoder::new(Some("gzip")), &enc), b"first second");
    }

    #[test]
    fn truncated_gzip_fails() {
        let mut g = GzEncoder::new(Vec::new(), Compression::default());
        g.write_all(&[1u8; 10000]).unwrap();
        let enc = g.finish().unwrap();
        let mut d = Decoder::new(Some("gzip"));
        let mut out = Vec::new();
        d.feed(&enc[..enc.len() / 2]);
        drain(&mut d, &mut out).unwrap();
        d.end();
        assert!(drain(&mut d, &mut out).is_err());
    }

    /// One small input that expands to far more than one step comes out in steps of `OUT` at most.
    #[test]
    fn bomb_comes_out_in_steps() {
        let mut g = GzEncoder::new(Vec::new(), Compression::best());
        g.write_all(&vec![0u8; 16 << 20]).unwrap();
        let enc = g.finish().unwrap();
        assert!(enc.len() < 64 << 10);
        let mut d = Decoder::new(Some("gzip"));
        d.feed(&enc);
        let mut total = 0;
        while let Some(piece) = d.next().unwrap() {
            assert!(!piece.is_empty() && piece.len() <= OUT);
            total += piece.len();
        }
        d.end();
        assert!(d.next().unwrap().is_none());
        assert_eq!(total, 16 << 20);
    }

}
