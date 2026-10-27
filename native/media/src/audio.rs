//! Audio decoding for the media player (src/media/audio_decode_rust.odin): Symphonia for the containers' usual codecs
//! (AAC-LC, MP3, FLAC, Vorbis, PCM) and libopus-less pure-Rust Opus is not mature, so Opus goes through the `opus`
//! crate (Xiph's libopus, built by `cc`). The decoder takes coded frames (one access unit at a time, as the container
//! stored them) and returns interleaved 32-bit float PCM, the format the output wants.
//!
//! One decoder decodes one track; the track's codec and its private data (the AudioSpecificConfig of AAC, the OpusHead
//! of Opus, the FLAC STREAMINFO, Vorbis' setup headers) come from the container. Symphonia decoders are packet based:
//! we drive them without its format readers, since Wren's container parsers (mp4.odin, webm.odin) already split the
//! stream into samples. Everything runs on the player's decode thread; nothing keeps global state.

use std::collections::VecDeque;
use std::ffi::c_void;

use symphonia::core::audio::{AudioBufferRef, Signal};
use symphonia::core::codecs::{CodecParameters, Decoder as SymDecoder, DecoderOptions, CODEC_TYPE_AAC, CODEC_TYPE_FLAC, CODEC_TYPE_MP3, CODEC_TYPE_PCM_S16LE, CODEC_TYPE_VORBIS};
use symphonia::core::formats::Packet;

use crate::{ERR_CORRUPT, ERR_UNSUPPORTED};

pub const AGAIN: i32 = 1;

/// The codecs the audio path accepts, the same numbers as `media.Codec` on the Odin side (types.odin). Only the audio
/// ones reach here.
pub const CODEC_AAC: u32 = 6;
pub const CODEC_OPUS: u32 = 7;
pub const CODEC_VORBIS: u32 = 8;
pub const CODEC_MP3: u32 = 9;
pub const CODEC_FLAC: u32 = 10;
pub const CODEC_PCM: u32 = 11;

/// One decoded block, interleaved 32-bit float, read by the Odin side and copied into an `Audio_Block`. The samples
/// live in the decoder until the next `get` or until it is dropped.
#[repr(C)]
pub struct Block {
    pub pts: i64,
    pub frames: u32,
    pub channels: u32,
    pub rate: u32,
    pub samples: *const f32, // frames * channels, owned by the decoder
}

/// A track's decoder: Symphonia for everything but Opus, the `opus` crate for Opus.
pub enum Decoder {
    Sym(SymState),
    Opus(OpusState),
}

pub struct SymState {
    dec: Box<dyn SymDecoder>,
    rate: u32,
    channels: u32,
    out: Vec<f32>,   // the last block, interleaved f32; kept until the next get
    last_pts: i64,
}

pub struct OpusState {
    dec: opus::Decoder,
    rate: u32,
    channels: u32,
    pre_skip: u32,   // samples to drop at the start of the stream (OpusHead pre-skip, at 48 kHz)
    skipped: u32,
    out: Vec<f32>,
    pending: VecDeque<(i64, Vec<u8>)>, // packets waiting for output to be taken
    last_pts: i64,
}

fn codec_type(codec: u32) -> Option<symphonia::core::codecs::CodecType> {
    Some(match codec {
        CODEC_AAC => CODEC_TYPE_AAC,
        CODEC_MP3 => CODEC_TYPE_MP3,
        CODEC_FLAC => CODEC_TYPE_FLAC,
        CODEC_VORBIS => CODEC_TYPE_VORBIS,
        CODEC_PCM => CODEC_TYPE_PCM_S16LE,
        _ => return None,
    })
}

impl Decoder {
    /// Makes a decoder for a track. `config` is the codec private data as the container stored it (may be empty for
    /// MP3 and raw PCM). `rate` and `channels` come from the container's header (0 when it does not say).
    pub fn open(codec: u32, config: &[u8], rate: u32, channels: u32, pre_skip: u32) -> Result<Box<Decoder>, i32> {
        if codec == CODEC_OPUS {
            let ch = if channels == 0 { 2 } else { channels } as usize;
            let chmap = if ch >= 2 { opus::Channels::Stereo } else { opus::Channels::Mono };
            // Opus always decodes at 48 kHz; the output resamples if the device wants another rate.
            let dec = opus::Decoder::new(48_000, chmap).map_err(|_| ERR_UNSUPPORTED)?;
            return Ok(Box::new(Decoder::Opus(OpusState {
                dec,
                rate: 48_000,
                channels: ch as u32,
                pre_skip,
                skipped: 0,
                out: Vec::new(),
                pending: VecDeque::new(),
                last_pts: 0,
            })));
        }
        let ct = codec_type(codec).ok_or(ERR_UNSUPPORTED)?;
        let mut params = CodecParameters::new();
        params.for_codec(ct);
        if rate != 0 {
            params.with_sample_rate(rate);
        }
        if !config.is_empty() {
            params.with_extra_data(config.to_vec().into_boxed_slice());
        }
        let dec = symphonia::default::get_codecs()
            .make(&params, &DecoderOptions::default())
            .map_err(|_| ERR_UNSUPPORTED)?;
        let r = dec.codec_params().sample_rate.unwrap_or(rate);
        let c = dec
            .codec_params()
            .channels
            .map(|c| c.count() as u32)
            .unwrap_or(if channels == 0 { 2 } else { channels });
        Ok(Box::new(Decoder::Sym(SymState {
            dec,
            rate: if r == 0 { 48_000 } else { r },
            channels: if c == 0 { 2 } else { c },
            out: Vec::new(),
            last_pts: 0,
        })))
    }

    /// Takes one coded frame. AGAIN: output is waiting, take it first (only Opus, which batches at most one frame).
    pub fn send(&mut self, data: &[u8], pts: i64) -> Result<i32, i32> {
        match self {
            Decoder::Sym(s) => {
                let packet = Packet::new_from_slice(0, pts.max(0) as u64, 0, data);
                match s.dec.decode(&packet) {
                    Ok(buf) => {
                        interleave(buf, &mut s.out);
                        s.last_pts = pts;
                        Ok(0)
                    }
                    // A bad frame is dropped; the stream recovers at the next one (as browsers do).
                    Err(symphonia::core::errors::Error::DecodeError(_)) => {
                        s.out.clear();
                        Ok(0)
                    }
                    Err(_) => Err(ERR_CORRUPT),
                }
            }
            Decoder::Opus(o) => {
                if !o.out.is_empty() {
                    return Ok(AGAIN);
                }
                o.pending.push_back((pts, data.to_vec()));
                o.decode_pending()?;
                Ok(0)
            }
        }
    }

    /// The last decoded block, or AGAIN when nothing is ready.
    pub fn get(&mut self, out: &mut Block) -> Result<i32, i32> {
        match self {
            Decoder::Sym(s) => {
                if s.out.is_empty() {
                    return Ok(AGAIN);
                }
                out.pts = s.last_pts;
                out.channels = s.channels;
                out.rate = s.rate;
                out.frames = (s.out.len() / s.channels.max(1) as usize) as u32;
                out.samples = s.out.as_ptr();
                Ok(0)
            }
            Decoder::Opus(o) => {
                if o.out.is_empty() {
                    o.decode_pending()?;
                }
                if o.out.is_empty() {
                    return Ok(AGAIN);
                }
                out.pts = o.last_pts;
                out.channels = o.channels;
                out.rate = o.rate;
                out.frames = (o.out.len() / o.channels.max(1) as usize) as u32;
                out.samples = o.out.as_ptr();
                Ok(0)
            }
        }
    }

    /// Marks the last block consumed, so the next get decodes more.
    pub fn taken(&mut self) {
        match self {
            Decoder::Sym(s) => s.out.clear(),
            Decoder::Opus(o) => o.out.clear(),
        }
    }

    pub fn flush(&mut self) {
        match self {
            Decoder::Sym(s) => {
                s.dec.reset();
                s.out.clear();
            }
            Decoder::Opus(o) => {
                o.out.clear();
                o.pending.clear();
                o.skipped = 0; // a seek: the pre-skip applies only to the true start of the stream, but reset is safe
            }
        }
    }
}

impl OpusState {
    fn decode_pending(&mut self) -> Result<(), i32> {
        while let Some((pts, pkt)) = self.pending.pop_front() {
            // 120 ms at 48 kHz is the longest an Opus packet can hold.
            let max_frames = 48_000 / 1000 * 120;
            let mut pcm = vec![0f32; max_frames * self.channels as usize];
            let got = self
                .dec
                .decode_float(&pkt, &mut pcm, false)
                .map_err(|_| ERR_CORRUPT)?;
            pcm.truncate(got * self.channels as usize);
            // Drop the pre-skip samples (encoder delay) off the very start of the stream.
            if self.skipped < self.pre_skip {
                let drop = ((self.pre_skip - self.skipped) as usize).min(got);
                self.skipped += drop as u32;
                pcm.drain(0..drop * self.channels as usize);
            }
            if pcm.is_empty() {
                continue;
            }
            self.out = pcm;
            self.last_pts = pts;
            return Ok(());
        }
        Ok(())
    }
}

/// Copies a Symphonia buffer of any sample format into interleaved f32 in `out`.
fn interleave(buf: AudioBufferRef, out: &mut Vec<f32>) {
    use symphonia::core::audio::AudioBufferRef::*;
    let spec = buf.spec();
    let channels = spec.channels.count();
    let frames = buf.frames();
    out.clear();
    out.resize(frames * channels, 0.0);
    macro_rules! copy_planes {
        ($b:expr, $conv:expr) => {{
            for ch in 0..channels {
                let plane = $b.chan(ch);
                for f in 0..frames {
                    out[f * channels + ch] = $conv(plane[f]);
                }
            }
        }};
    }
    match buf {
        F32(b) => copy_planes!(b, |x: f32| x),
        F64(b) => copy_planes!(b, |x: f64| x as f32),
        S32(b) => copy_planes!(b, |x: i32| x as f32 / i32::MAX as f32),
        S24(b) => copy_planes!(b, |x: symphonia::core::sample::i24| x.inner() as f32 / 8_388_608.0),
        U24(b) => copy_planes!(b, |x: symphonia::core::sample::u24| (x.inner() as f32 - 8_388_608.0) / 8_388_608.0),
        S16(b) => copy_planes!(b, |x: i16| x as f32 / 32_768.0),
        U16(b) => copy_planes!(b, |x: u16| (x as f32 - 32_768.0) / 32_768.0),
        S8(b) => copy_planes!(b, |x: i8| x as f32 / 128.0),
        U8(b) => copy_planes!(b, |x: u8| (x as f32 - 128.0) / 128.0),
    }
}

/// # Safety
/// `handle` comes from `wm_audio_open` and is released once.
pub unsafe fn close(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    drop(Box::from_raw(handle as *mut Decoder));
}

/// Whether a codec can be decoded here (asked before a source is accepted). Opus and the Symphonia codecs; everything
/// else falls to the system (none on Linux yet) or is refused.
pub fn supported(codec: u32) -> bool {
    codec == CODEC_OPUS || codec_type(codec).is_some()
}
