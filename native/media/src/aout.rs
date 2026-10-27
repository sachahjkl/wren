//! Audio output for the media player (src/media/audio_out_cpal.odin): cpal drives the system's audio (ALSA, which
//! PipeWire and PulseAudio serve), so the player writes interleaved stereo float PCM and reads where playback is, the
//! way WASAPI does on Windows (wasapi_windows.odin). cpal owns a device thread; its data callback pulls from a ring
//! this code fills, counts the audible frames it played (silence while the ring is empty does not count), and the
//! media clock follows that count.
//!
//! The stream is always stereo float32 at the rate the output was opened with. cpal picks a device configuration whose
//! sample rate matches when it can; when the device's only rate differs, a linear resampler converts (the player opens
//! at the media's rate, so a resample is the exception, not the rule).

use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;

const CHANNELS: usize = 2;

/// The shared state between the player's threads and the cpal callback. The ring holds half a second of stereo frames.
struct Shared {
    ring: Mutex<Ring>,
    // position published for the reader: audible frames played since the last flush, and the mono time it is true at
    pos_frames: AtomicI64,
    pos_at: AtomicI64,
    gain: AtomicU32,  // f32 bits
    failed: AtomicBool,
    // the device rate (may differ from the stream rate: then the callback resamples)
    device_rate: AtomicU32,
    stream_rate: u32,
    // cumulative audible frames at the stream rate (what the clock counts), advanced by the callback
    audio_total: AtomicI64,
    // fractional device position carried across callbacks for the resampler
    resample_pos: AtomicU64, // f64 bits of the read cursor into the ring, in stream frames
}

struct Ring {
    buf: Vec<f32>, // capacity * CHANNELS
    capacity: usize,
    rd: i64, // frames consumed by the device, monotonic within a flush epoch
    wr: i64, // frames written by the player
}

pub struct Output {
    shared: Arc<Shared>,
    stream: Option<cpal::Stream>,
    rate: u32,
    running: bool,
}

// cpal's Stream is not Send on every host; the Odin side opens, uses and closes the output on one thread (the player's
// audio thread), so the handle never crosses threads. The shared state behind the Arc is Send + Sync (atomics and a
// Mutex), which is what the callback touches.
unsafe impl Send for Output {}

fn mono_ns() -> i64 {
    // CLOCK_MONOTONIC, as the Odin side stamps its times (thread_linux.odin: time.tick_now).
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: a valid timespec slot.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as i64 * 1_000_000_000 + ts.tv_nsec as i64
}

impl Output {
    pub fn open(rate: u32) -> Result<Box<Output>, i32> {
        let host = cpal::default_host();
        let device = host.default_output_device().ok_or(1i32)?;
        // A configuration with our two channels and, if the device allows it, our rate; else the device's default.
        let wanted = cpal::SampleRate(rate);
        let mut chosen: Option<cpal::SupportedStreamConfig> = None;
        if let Ok(ranges) = device.supported_output_configs() {
            for r in ranges {
                if r.channels() as usize >= CHANNELS
                    && r.min_sample_rate() <= wanted
                    && r.max_sample_rate() >= wanted
                {
                    chosen = Some(r.with_sample_rate(wanted));
                    break;
                }
            }
        }
        let supported = match chosen {
            Some(c) => c,
            None => device.default_output_config().map_err(|_| 1i32)?,
        };
        let device_rate = supported.sample_rate().0;
        let sample_format = supported.sample_format();
        let config: cpal::StreamConfig = supported.config();
        let out_channels = config.channels as usize;

        let capacity = (rate as usize / 2).max(4096);
        let shared = Arc::new(Shared {
            ring: Mutex::new(Ring {
                buf: vec![0.0; capacity * CHANNELS],
                capacity,
                rd: 0,
                wr: 0,
            }),
            pos_frames: AtomicI64::new(0),
            pos_at: AtomicI64::new(0),
            gain: AtomicU32::new(1f32.to_bits()),
            failed: AtomicBool::new(false),
            device_rate: AtomicU32::new(device_rate),
            stream_rate: rate,
            audio_total: AtomicI64::new(0),
            resample_pos: AtomicU64::new(0.0f64.to_bits()),
        });

        let cb_shared = shared.clone();
        let err_shared = shared.clone();
        let err_fn = move |_err| err_shared.failed.store(true, Ordering::Release);

        let build = |fmt: SampleFormat| -> Result<cpal::Stream, cpal::BuildStreamError> {
            match fmt {
                SampleFormat::F32 => device.build_output_stream(
                    &config,
                    move |data: &mut [f32], _| fill(&cb_shared, data, out_channels, |s, o| *o = s),
                    err_fn.clone(),
                    None,
                ),
                SampleFormat::I16 => device.build_output_stream(
                    &config,
                    move |data: &mut [i16], _| fill(&cb_shared, data, out_channels, |s, o| *o = (s.clamp(-1.0, 1.0) * 32_767.0) as i16),
                    err_fn.clone(),
                    None,
                ),
                SampleFormat::U16 => device.build_output_stream(
                    &config,
                    move |data: &mut [u16], _| fill(&cb_shared, data, out_channels, |s, o| *o = ((s.clamp(-1.0, 1.0) * 0.5 + 0.5) * 65_535.0) as u16),
                    err_fn.clone(),
                    None,
                ),
                _ => Err(cpal::BuildStreamError::StreamConfigNotSupported),
            }
        };
        let stream = build(sample_format).map_err(|_| 1i32)?;
        Ok(Box::new(Output {
            shared,
            stream: Some(stream),
            rate,
            running: false,
        }))
    }

    pub fn write(&mut self, samples: &[f32]) -> i32 {
        let frames = samples.len() / CHANNELS;
        let mut ring = self.shared.ring.lock().unwrap();
        let room = ring.capacity - (ring.wr - ring.rd) as usize;
        let n = frames.min(room);
        let cap = ring.capacity;
        for i in 0..n {
            let k = ((ring.wr as usize + i) % cap) * CHANNELS;
            ring.buf[k] = samples[i * CHANNELS];
            ring.buf[k + 1] = samples[i * CHANNELS + 1];
        }
        ring.wr += n as i64;
        n as i32
    }

    pub fn room(&self) -> i32 {
        let ring = self.shared.ring.lock().unwrap();
        (ring.capacity - (ring.wr - ring.rd) as usize) as i32
    }

    pub fn queued(&self) -> i32 {
        let ring = self.shared.ring.lock().unwrap();
        let played = self.shared.pos_frames.load(Ordering::Acquire);
        (ring.wr - played) as i32
    }

    pub fn position(&self) -> (i64, i64) {
        (
            self.shared.pos_frames.load(Ordering::Acquire),
            self.shared.pos_at.load(Ordering::Acquire),
        )
    }

    pub fn start(&mut self) {
        if !self.running {
            if let Some(s) = &self.stream {
                if s.play().is_err() {
                    self.shared.failed.store(true, Ordering::Release);
                } else {
                    self.running = true;
                }
            }
        }
    }

    pub fn stop(&mut self) {
        if self.running {
            if let Some(s) = &self.stream {
                let _ = s.pause();
            }
            self.running = false;
        }
    }

    pub fn flush(&mut self) {
        let mut ring = self.shared.ring.lock().unwrap();
        ring.rd = 0;
        ring.wr = 0;
        self.shared.audio_total.store(0, Ordering::Release);
        self.shared.resample_pos.store(0.0f64.to_bits(), Ordering::Release);
        self.shared.pos_frames.store(0, Ordering::Release);
        self.shared.pos_at.store(0, Ordering::Release);
    }

    pub fn set_gain(&mut self, gain: f32) {
        self.shared.gain.store(gain.clamp(0.0, 4.0).to_bits(), Ordering::Release);
    }

    pub fn failed(&self) -> bool {
        self.shared.failed.load(Ordering::Acquire)
    }

    pub fn rate(&self) -> u32 {
        self.rate
    }
}

/// The device callback: pulls stereo frames from the ring (with the gain), writes them spread across the device's
/// channels, pads the rest with silence, and publishes the audible position. When the device rate differs from the
/// stream rate, a linear resampler reads the ring at the ratio.
fn fill<T: Copy + Default, F: Fn(f32, &mut T)>(shared: &Arc<Shared>, data: &mut [T], out_channels: usize, put: F) {
    let device_rate = shared.device_rate.load(Ordering::Acquire);
    let gain = f32::from_bits(shared.gain.load(Ordering::Acquire));
    let out_frames = data.len() / out_channels;
    let mut audible: i64 = 0;
    {
        let mut ring = shared.ring.lock().unwrap();
        let cap = ring.capacity;
        if device_rate == shared.stream_rate {
            for f in 0..out_frames {
                let have = (ring.wr - ring.rd) > 0;
                let (mut l, mut r) = (0.0f32, 0.0f32);
                if have {
                    let k = (ring.rd as usize % cap) * CHANNELS;
                    l = ring.buf[k] * gain;
                    r = ring.buf[k + 1] * gain;
                    ring.rd += 1;
                    audible += 1;
                }
                write_frame(&put, &mut data[f * out_channels..(f + 1) * out_channels], l, r, out_channels);
            }
        } else {
            // Linear resample: step through the ring at stream_rate / device_rate per output frame.
            let step = shared.stream_rate as f64 / device_rate as f64;
            let mut pos = f64::from_bits(shared.resample_pos.load(Ordering::Acquire));
            for f in 0..out_frames {
                let avail = (ring.wr - ring.rd) as f64;
                let (mut l, mut r) = (0.0f32, 0.0f32);
                if pos + 1.0 < avail {
                    let i0 = ring.rd as usize + pos as usize;
                    let frac = pos.fract() as f32;
                    let k0 = (i0 % cap) * CHANNELS;
                    let k1 = ((i0 + 1) % cap) * CHANNELS;
                    l = (ring.buf[k0] * (1.0 - frac) + ring.buf[k1] * frac) * gain;
                    r = (ring.buf[k0 + 1] * (1.0 - frac) + ring.buf[k1 + 1] * frac) * gain;
                    pos += step;
                }
                write_frame(&put, &mut data[f * out_channels..(f + 1) * out_channels], l, r, out_channels);
            }
            // Advance the ring by the whole stream frames consumed; keep the fraction for the next callback.
            let whole = pos.floor();
            ring.rd += whole as i64;
            pos -= whole;
            shared.resample_pos.store(pos.to_bits(), Ordering::Release);
            audible = whole as i64;
        }
    }
    let total = shared.audio_total.fetch_add(audible, Ordering::AcqRel) + audible;
    shared.pos_frames.store(total, Ordering::Release);
    shared.pos_at.store(mono_ns(), Ordering::Release);
}

#[inline]
fn write_frame<T: Copy + Default, F: Fn(f32, &mut T)>(put: &F, frame: &mut [T], l: f32, r: f32, out_channels: usize) {
    // Front left / right carry the stereo; the device's other channels (centre, surrounds, LFE) get silence.
    for (ch, slot) in frame.iter_mut().enumerate() {
        let s = match ch {
            0 => l,
            1 => r,
            _ => 0.0,
        };
        put(s, slot);
    }
    let _ = out_channels;
}

/// # Safety
/// `handle` comes from `wm_aout_open` and is released once.
pub unsafe fn close(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    drop(Box::from_raw(handle as *mut Output));
}
