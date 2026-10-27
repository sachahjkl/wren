//! One HTTP request from start to end: the request built from package net's description, sent over a pooled HTTP/1.1
//! or HTTP/2 connection (hyper-util's client and our connector) or over HTTP/3 when the origin announced it, the head
//! reported, then the body decoded, cut into `read_chunk` pieces and handed over under back-pressure.

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use bytes::Bytes;
use futures_util::FutureExt;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper_util::client::legacy::Client as Legacy;
use hyper_util::rt::{TokioExecutor, TokioTimer};

use crate::conn::{ConnInfo, Connector};
use crate::decode::Decoder;
use crate::error::{self, NetError};
use crate::{since, Ev, Inner, ReqState, Shared, EV_DATA, EV_DONE, EV_FAILED, EV_HEADERS};

pub(crate) type HttpClient = Legacy<Connector, Full<Bytes>>;

pub(crate) fn build_client(shared: Arc<Shared>, idle_ms: u32, max_idle: u32) -> HttpClient {
    let mut b = Legacy::builder(TokioExecutor::new());
    b.pool_timer(TokioTimer::new())
        .timer(TokioTimer::new())
        .pool_idle_timeout(Duration::from_millis(if idle_ms == 0 { 90_000 } else { idle_ms as u64 }))
        .pool_max_idle_per_host(if max_idle == 0 { usize::MAX } else { max_idle as usize })
        .http2_adaptive_window(true)
        .retry_canceled_requests(true);
    b.build(Connector { shared })
}

pub(crate) struct Desc {
    pub url: String,
    pub method: Vec<u8>,
    pub headers: Vec<u8>,
    pub body: Bytes,
    pub start: Instant,
}

/// Timing marks of one request, as instants (turned into ms from `start` for the host).
#[derive(Default)]
pub(crate) struct Marks {
    pub dns_start: Option<Instant>,
    pub dns_end: Option<Instant>,
    pub connect_start: Option<Instant>,
    pub connect_end: Option<Instant>,
    pub sending: Option<Instant>,
    pub response: Option<Instant>,
    pub done: Option<Instant>,
}

impl Marks {
    /// The connection's own marks count only when it was opened for this request (a reused one has none).
    pub fn take_conn(&mut self, start: Instant, c: &ConnInfo) {
        if c.connect_start.map(|t| t >= start).unwrap_or(false) {
            self.dns_start = c.dns_start;
            self.dns_end = c.dns_end;
            self.connect_start = c.connect_start;
            self.connect_end = c.connect_end;
            self.sending = c.secure_end.or(c.connect_end);
        }
    }

    pub fn timing(&self, start: Instant) -> [f32; 9] {
        let sending = self.sending.unwrap_or(start);
        [
            0.0,
            since(start, self.dns_start),
            since(start, self.dns_end),
            since(start, self.connect_start),
            since(start, self.connect_end),
            since(start, Some(sending)),
            since(start, Some(sending)),
            since(start, self.response),
            since(start, self.done),
        ]
    }
}

pub(crate) fn parse_headers(raw: &[u8], into: &mut http::HeaderMap) -> Result<(), NetError> {
    for line in raw.split(|&b| b == b'\n') {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.iter().all(|b| b.is_ascii_whitespace()) { continue; }
        let Some(colon) = line.iter().position(|&b| b == b':') else { return Err(NetError::new(error::ERROR_START_FAILED)) };
        let name = http::HeaderName::from_bytes(line[..colon].trim_ascii()).map_err(|_| NetError::new(error::ERROR_START_FAILED))?;
        let value = http::HeaderValue::from_bytes(line[colon + 1..].trim_ascii()).map_err(|_| NetError::new(error::ERROR_START_FAILED))?;
        into.append(name, value);
    }
    Ok(())
}

/// The head as WinHTTP's WINHTTP_QUERY_RAW_HEADERS_CRLF gave it: the status line, the fields, an empty line.
pub(crate) fn head_block(version: http::Version, status: http::StatusCode, reason: Option<&[u8]>, headers: &http::HeaderMap) -> Vec<u8> {
    let mut b = Vec::with_capacity(512);
    b.extend_from_slice(match version {
        http::Version::HTTP_10 => b"HTTP/1.0 ",
        http::Version::HTTP_2 => b"HTTP/2 ",
        http::Version::HTTP_3 => b"HTTP/3 ",
        _ => b"HTTP/1.1 ",
    });
    b.extend_from_slice(status.as_str().as_bytes());
    b.push(b' ');
    b.extend_from_slice(reason.unwrap_or(status.canonical_reason().unwrap_or("").as_bytes()));
    b.extend_from_slice(b"\r\n");
    for (n, v) in headers {
        b.extend_from_slice(n.as_str().as_bytes());
        b.extend_from_slice(b": ");
        b.extend_from_slice(v.as_bytes());
        b.extend_from_slice(b"\r\n");
    }
    b.extend_from_slice(b"\r\n");
    b
}

pub(crate) fn remote_text(addr: Option<std::net::SocketAddr>) -> Vec<u8> {
    match addr {
        Some(std::net::SocketAddr::V4(a)) => format!("{}:{}", a.ip(), a.port()).into_bytes(),
        Some(std::net::SocketAddr::V6(a)) => format!("{}:{}", a.ip(), a.port()).into_bytes(),
        None => Vec::new(),
    }
}

/// The body of a response, from whichever protocol carried it.
pub(crate) enum Body {
    Hyper(Incoming),
    H3(crate::h3conn::H3Body),
}

impl Body {
    async fn next(&mut self) -> Result<Option<Bytes>, NetError> {
        match self {
            Body::Hyper(b) => loop {
                match b.frame().await {
                    None => return Ok(None),
                    Some(Err(e)) => return Err(error::from_any(&e, error::CONNECTION_ERROR)),
                    Some(Ok(f)) => {
                        if let Ok(d) = f.into_data() {
                            return Ok(Some(d));
                        }
                    }
                }
            },
            Body::H3(b) => b.next().await,
        }
    }
}

pub(crate) async fn run(inner: Arc<Inner>, id: u64, st: Arc<ReqState>, d: Desc) {
    let tag = st.tag;
    let r = std::panic::AssertUnwindSafe(request(&inner, id, &st, d)).catch_unwind().await;
    match r {
        Ok(Ok(())) => {}
        Ok(Err(e)) => inner.fail(tag, EV_FAILED, e),
        Err(_) => inner.fail(tag, EV_FAILED, NetError::new(error::CONNECTION_ERROR)),
    }
    inner.finished(id);
}

fn build_request(inner: &Inner, d: &Desc) -> Result<http::Request<Bytes>, NetError> {
    let uri: http::Uri = d.url.parse().map_err(|_| NetError::new(error::ERROR_BAD_URL))?;
    if !matches!(uri.scheme_str(), Some("http") | Some("https")) || uri.host().is_none() {
        return Err(NetError::new(error::ERROR_BAD_URL));
    }
    let method = if d.method.is_empty() { http::Method::GET } else {
        http::Method::from_bytes(&d.method).map_err(|_| NetError::new(error::ERROR_START_FAILED))?
    };
    let mut req = http::Request::new(d.body.clone());
    *req.method_mut() = method;
    *req.uri_mut() = uri;
    parse_headers(&d.headers, req.headers_mut())?;
    let h = req.headers_mut();
    if !h.contains_key(http::header::USER_AGENT) {
        let ua = inner.shared.settings().user_agent;
        if let Ok(v) = http::HeaderValue::from_str(&ua) { h.insert(http::header::USER_AGENT, v); }
    }
    if !h.contains_key(http::header::ACCEPT_ENCODING) {
        h.insert(http::header::ACCEPT_ENCODING, http::HeaderValue::from_static("gzip, deflate, br"));
    }
    Ok(req)
}

async fn timeout_at<T>(deadline: Option<Instant>, f: impl std::future::Future<Output = Result<T, NetError>>) -> Result<T, NetError> {
    match deadline {
        Some(t) => tokio::time::timeout_at(t.into(), f).await.unwrap_or(Err(NetError::new(error::TIMEOUT))),
        None => f.await,
    }
}

async fn request(inner: &Arc<Inner>, id: u64, st: &Arc<ReqState>, d: Desc) -> Result<(), NetError> {
    let start = d.start;
    let s = inner.shared.settings();
    let req = build_request(inner, &d)?;
    let idempotent = matches!(*req.method(), http::Method::GET | http::Method::HEAD | http::Method::OPTIONS);
    // the head must come within the connection's own timeouts plus send + receive
    let deadline = match (s.send, s.receive) {
        (Some(a), Some(b)) => Some(start + a + b + s.resolve.unwrap_or_default() + s.connect.unwrap_or_default()),
        _ => None,
    };
    let mut marks = Marks::default();

    // HTTP/3 when the origin announced it (Alt-Svc) and QUIC worked there: raced against TCP
    let mut h3_resp = None;
    if s.http3 && req.uri().scheme_str() == Some("https") {
        if let Some(target) = inner.h3.candidate(req.uri()) {
            match inner.h3.try_send(&req, target, s.h3_race, idempotent).await {
                crate::h3conn::Outcome::Sent(r) => h3_resp = Some(r),
                crate::h3conn::Outcome::UseTcp => {}
                crate::h3conn::Outcome::Failed(e) => return Err(e),
            }
        }
    }

    let (version, status, reason, headers, info, mut body) = match h3_resp {
        Some((resp, body, info)) => {
            let (parts, ()) = resp.into_parts();
            (http::Version::HTTP_3, parts.status, None, parts.headers, info, Body::H3(body))
        }
        None => {
            let (parts, body) = req.into_parts();
            let req = http::Request::from_parts(parts, Full::new(body));
            let resp = timeout_at(deadline, async {
                inner.http.request(req).await.map_err(|e| error::from_any(&e, error::CANNOT_CONNECT))
            })
            .await?;
            let info = resp.extensions().get::<ConnInfo>().cloned().unwrap_or_default();
            let reason = resp.extensions().get::<hyper::ext::ReasonPhrase>().map(|r| r.as_bytes().to_vec());
            let (parts, body) = resp.into_parts();
            (parts.version, parts.status, reason, parts.headers, info, Body::Hyper(body))
        }
    };
    marks.take_conn(start, &info);
    marks.response = Some(Instant::now());
    if s.http3 {
        if let Some(v) = headers.get(http::header::ALT_SVC).and_then(|v| v.to_str().ok()) {
            inner.h3.note_alt_svc(&d.url, v);
        }
    }

    let mut ev = Ev {
        kind: EV_HEADERS,
        tag: st.tag,
        status: status.as_u16() as u32,
        protocol: match version { http::Version::HTTP_2 => 1, http::Version::HTTP_3 => 2, _ => 0 },
        headers: head_block(version, status, reason.as_deref(), &headers),
        url: d.url.clone().into_bytes(),
        timing: marks.timing(start),
        remote: remote_text(info.remote),
        ..Default::default()
    };
    ev.timing[0] = 0.0;
    inner.push(ev);

    let encoding = headers.get(http::header::CONTENT_ENCODING).and_then(|v| v.to_str().ok());
    let mut dec = Decoder::new(encoding);
    let mut total: u64 = 0;
    loop {
        let chunk = match s.receive {
            Some(t) => tokio::time::timeout(t, body.next()).await.unwrap_or(Err(NetError::new(error::TIMEOUT)))?,
            None => body.next().await?,
        };
        let Some(chunk) = chunk else { break };
        if dec.is_identity() {
            deliver(inner, id, st, &s, &chunk, &mut total).await?;
        } else {
            for piece in chunk.chunks(8 << 10) {
                let out = dec.push(piece).map_err(|_| NetError::new(error::INVALID_SERVER_RESPONSE))?;
                deliver(inner, id, st, &s, &out, &mut total).await?;
            }
        }
    }
    let tail = dec.finish().map_err(|_| NetError::new(error::INVALID_SERVER_RESPONSE))?;
    deliver(inner, id, st, &s, &tail, &mut total).await?;
    marks.done = Some(Instant::now());
    inner.push(Ev { kind: EV_DONE, tag: st.tag, timing: marks.timing(start), ..Default::default() });
    Ok(())
}

/// Hands decoded bytes to the host in `read_chunk` pieces, waiting while too much is unconsumed.
async fn deliver(inner: &Inner, _id: u64, st: &ReqState, s: &crate::Settings, data: &[u8], total: &mut u64) -> Result<(), NetError> {
    for piece in data.chunks(s.read_chunk) {
        *total += piece.len() as u64;
        if *total > st.max_body.load(Ordering::Acquire) {
            return Err(NetError::new(error::ERROR_BODY_TOO_LARGE));
        }
        inner.push(Ev { kind: EV_DATA, tag: st.tag, data: piece.to_vec(), ..Default::default() });
        let q = st.queued.fetch_add(piece.len(), Ordering::AcqRel) + piece.len();
        if q >= s.high_water {
            loop {
                let woken = st.wake.notified();
                let low = inner.shared.settings().low_water;
                if st.queued.load(Ordering::Acquire) < low { break; }
                woken.await;
            }
        }
    }
    Ok(())
}
