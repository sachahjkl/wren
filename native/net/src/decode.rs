//! Content-Encoding, decoded as the body streams in (what WinHTTP's decompression did, with Brotli on top). As with
//! WinHTTP, the head the host reads then has no Content-Encoding nor Content-Length (http.rs).

use std::io::{self, Write};

pub(crate) enum Decoder {
    Identity,
    Gzip(flate2::write::MultiGzDecoder<Vec<u8>>),
    /// "deflate": zlib as the standard says, or the raw stream some servers send (told by the first two bytes)
    DeflateUnknown(Vec<u8>),
    Zlib(flate2::write::ZlibDecoder<Vec<u8>>),
    Raw(flate2::write::DeflateDecoder<Vec<u8>>),
    Br(Box<brotli_decompressor::DecompressorWriter<Vec<u8>>>),
}

impl Decoder {
    /// The decoder for a Content-Encoding value; anything else (several codings, unknown ones) is passed through.
    pub fn new(encoding: Option<&str>) -> Decoder {
        let Some(e) = encoding else { return Decoder::Identity };
        match e.trim().to_ascii_lowercase().as_str() {
            "gzip" | "x-gzip" => Decoder::Gzip(flate2::write::MultiGzDecoder::new(Vec::new())),
            "deflate" => Decoder::DeflateUnknown(Vec::new()),
            "br" => Decoder::Br(Box::new(brotli_decompressor::DecompressorWriter::new(Vec::new(), 16 << 10))),
            _ => Decoder::Identity,
        }
    }

    pub fn is_identity(&self) -> bool {
        matches!(self, Decoder::Identity)
    }

    /// Feeds encoded bytes, returns what they decoded to. Callers feed small pieces: one piece of deflate cannot
    /// expand to more than about a thousand times its size.
    pub fn push(&mut self, input: &[u8]) -> io::Result<Vec<u8>> {
        match self {
            Decoder::Identity => Ok(input.to_vec()),
            Decoder::Gzip(d) => {
                d.write_all(input)?;
                Ok(std::mem::take(d.get_mut()))
            }
            Decoder::DeflateUnknown(head) => {
                head.extend_from_slice(input);
                if head.len() < 2 { return Ok(Vec::new()); }
                let (b0, b1) = (head[0] as u16, head[1] as u16);
                let zlib = b0 & 0x0F == 8 && (b0 << 8 | b1) % 31 == 0;
                let pending = std::mem::take(head);
                *self = if zlib {
                    Decoder::Zlib(flate2::write::ZlibDecoder::new(Vec::new()))
                } else {
                    Decoder::Raw(flate2::write::DeflateDecoder::new(Vec::new()))
                };
                self.push(&pending)
            }
            Decoder::Zlib(d) => {
                d.write_all(input)?;
                Ok(std::mem::take(d.get_mut()))
            }
            Decoder::Raw(d) => {
                d.write_all(input)?;
                Ok(std::mem::take(d.get_mut()))
            }
            Decoder::Br(d) => {
                d.write_all(input)?;
                Ok(std::mem::take(d.get_mut()))
            }
        }
    }

    /// The end of the body: what the decoder still held. A truncated stream is an error.
    pub fn finish(self) -> io::Result<Vec<u8>> {
        match self {
            Decoder::Identity => Ok(Vec::new()),
            Decoder::Gzip(d) => d.finish(),
            Decoder::DeflateUnknown(head) => {
                if head.is_empty() { Ok(Vec::new()) } else { Err(io::Error::new(io::ErrorKind::InvalidData, "truncated deflate stream")) }
            }
            Decoder::Zlib(d) => d.finish(),
            Decoder::Raw(d) => d.finish(),
            Decoder::Br(mut d) => {
                d.flush()?;
                d.into_inner().map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "truncated brotli stream"))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::write::{GzEncoder, ZlibEncoder, DeflateEncoder};
    use flate2::Compression;

    fn roundtrip(mut d: Decoder, enc: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        for piece in enc.chunks(7) { out.extend(d.push(piece).unwrap()); }
        out.extend(d.finish().unwrap());
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
        assert_eq!(roundtrip(Decoder::new(Some("identity")), &text), text);
    }

    #[test]
    fn truncated_gzip_fails() {
        let mut g = GzEncoder::new(Vec::new(), Compression::default());
        g.write_all(&[1u8; 10000]).unwrap();
        let enc = g.finish().unwrap();
        let mut d = Decoder::new(Some("gzip"));
        let _ = d.push(&enc[..enc.len() / 2]).unwrap();
        assert!(d.finish().is_err());
    }
}
