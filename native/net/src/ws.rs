//! One WebSocket (RFC 6455) client: the HTTP/1.1 upgrade (over our connector: the system proxy is tunnelled through),
//! then tungstenite's framing. Package net keeps the policy and the state machine (src/net/websocket.odin): it reads the
//! handshake's answer and accepts it, queues one message at a time, and starts the closing handshake; this side reports
//! what WinHTTP's WebSocket API reported: the answer's head, whole messages, the peer's close frame, a write done, our
//! close frame gone out, a transport error. Pings are answered here; `keepalive` sends ours.
//! No permessage-deflate (WinHTTP offered none either).

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use std::future::Future;

use futures_util::{FutureExt, SinkExt, StreamExt};
use hyper_util::rt::TokioIo;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::{CloseFrame, Role, WebSocketConfig};
use tokio_tungstenite::tungstenite::{self, Message, Utf8Bytes};
use tokio_tungstenite::WebSocketStream;

use crate::conn::{self, Alpn};
use crate::error::{self, NetError};
use crate::http::{head_block, parse_headers};
use crate::{Ev, Inner, ReqState};
use crate::{EV_WS_ERROR, EV_WS_HANDSHAKE_FAILED, EV_WS_HEADERS, EV_WS_MESSAGE, EV_WS_PEER_CLOSE, EV_WS_SHUTDOWN_DONE, EV_WS_WRITE_DONE};

pub(crate) enum Cmd {
    Accept,
    Send { binary: bool, data: Vec<u8> },
    Shutdown { code: u16, reason: Vec<u8> },
}

pub(crate) struct Desc {
    pub url: String,
    pub headers: Vec<u8>,
    pub max_message: usize,
    pub keepalive: Option<Duration>,
    pub high_water: usize,
    pub low_water: usize,
}

// Web_Socket_Buffer_Type / Web_Socket_Operation of package net
const BINARY_MESSAGE: u32 = 0;
const UTF8_MESSAGE: u32 = 2;
const OP_SEND: u32 = 0;
const OP_RECEIVE: u32 = 1;
const OP_SHUTDOWN: u32 = 3;

pub(crate) async fn run(inner: Arc<Inner>, id: u64, st: Arc<ReqState>, d: Desc, rx: UnboundedReceiver<Cmd>) {
    let tag = st.tag;
    let r = std::panic::AssertUnwindSafe(socket(&inner, &st, d, rx)).catch_unwind().await;
    let (kind, op, e) = match r {
        Ok(Ok(())) => {
            inner.finished(id);
            return;
        }
        Ok(Err(f)) => f,
        Err(_) => (EV_WS_ERROR, OP_RECEIVE, NetError::new(error::CONNECTION_ERROR)),
    };
    inner.push(Ev { kind, tag, op, error: e.code, secure_flags: e.flags, ..Default::default() });
    inner.finished(id);
}

fn ws_error(e: &tungstenite::Error) -> NetError {
    use tungstenite::error::{CapacityError, ProtocolError};
    use tungstenite::Error as E;
    match e {
        E::Capacity(CapacityError::MessageTooLong { .. }) => NetError::new(error::WS_ERROR_MESSAGE_TOO_BIG),
        E::Capacity(_) => NetError::new(error::WS_ERROR_MESSAGE_TOO_BIG),
        E::Utf8(_) => NetError::new(error::WS_ERROR_INVALID_UTF8),
        E::Protocol(ProtocolError::ResetWithoutClosingHandshake) => NetError::new(error::CONNECTION_ERROR),
        E::Protocol(_) => NetError::new(error::WS_ERROR_PROTOCOL),
        E::Io(io) => error::from_io(io, error::CONNECTION_ERROR),
        E::Tls(_) => NetError { code: error::SECURE_FAILURE, flags: error::FLAG_CHANNEL_ERROR },
        _ => NetError::new(error::CONNECTION_ERROR),
    }
}

type Failure = (u32, u32, NetError); // event kind, operation, error

async fn socket(inner: &Arc<Inner>, st: &Arc<ReqState>, d: Desc, mut rx: UnboundedReceiver<Cmd>) -> Result<(), Failure> {
    let hs = |e: NetError| (EV_WS_HANDSHAKE_FAILED, 0, e);
    let ws_uri: http::Uri = d.url.parse().map_err(|_| hs(NetError::new(error::ERROR_BAD_URL)))?;
    let secure = match ws_uri.scheme_str() {
        Some("wss") => true,
        Some("ws") => false,
        _ => return Err(hs(NetError::new(error::ERROR_BAD_URL))),
    };
    let authority = ws_uri.authority().ok_or(hs(NetError::new(error::ERROR_BAD_URL)))?.clone();
    let path = ws_uri.path_and_query().map(|p| p.as_str()).unwrap_or("/").to_string();
    let http_uri: http::Uri = format!("{}://{}{}", if secure { "https" } else { "http" }, authority, path)
        .parse()
        .map_err(|_| hs(NetError::new(error::ERROR_BAD_URL)))?;

    let c = conn::connect(&inner.shared, &http_uri, Alpn::Ws).await.map_err(hs)?;
    let (mut sender, connection) = hyper::client::conn::http1::handshake(c)
        .await
        .map_err(|e| hs(error::from_any(&e, error::CONNECTION_ERROR)))?;
    tokio::spawn(async move {
        let _ = connection.with_upgrades().await;
    });

    let key = tungstenite::handshake::client::generate_key();
    let mut req = http::Request::new(http_body_util::Empty::<Bytes>::new());
    *req.uri_mut() = path.parse().map_err(|_| hs(NetError::new(error::ERROR_BAD_URL)))?;
    {
        let h = req.headers_mut();
        let default_port = if secure { 443 } else { 80 };
        let host = if conn::default_port(&ws_uri) == default_port {
            ws_uri.host().unwrap_or("").to_string()
        } else {
            authority.as_str().to_string()
        };
        h.insert(http::header::HOST, http::HeaderValue::from_str(&host).map_err(|_| hs(NetError::new(error::ERROR_BAD_URL)))?);
        h.insert(http::header::UPGRADE, http::HeaderValue::from_static("websocket"));
        h.insert(http::header::CONNECTION, http::HeaderValue::from_static("Upgrade"));
        h.insert(http::header::SEC_WEBSOCKET_KEY, http::HeaderValue::from_str(&key).unwrap());
        h.insert(http::header::SEC_WEBSOCKET_VERSION, http::HeaderValue::from_static("13"));
        parse_headers(&d.headers, h).map_err(hs)?;
        if !h.contains_key(http::header::USER_AGENT) {
            if let Ok(v) = http::HeaderValue::from_str(&inner.shared.settings().user_agent) {
                h.insert(http::header::USER_AGENT, v);
            }
        }
    }
    let resp = sender.send_request(req).await.map_err(|e| hs(error::from_any(&e, error::CONNECTION_ERROR)))?;
    let reason = resp.extensions().get::<hyper::ext::ReasonPhrase>().map(|r| r.as_bytes().to_vec());
    inner.push(Ev {
        kind: EV_WS_HEADERS,
        tag: st.tag,
        status: resp.status().as_u16() as u32,
        headers: head_block(resp.version(), resp.status(), reason.as_deref(), resp.headers()),
        ..Default::default()
    });

    // the host decides from the head; nothing else is done before it accepts
    loop {
        match rx.recv().await {
            Some(Cmd::Accept) => break,
            Some(_) => continue,
            None => return Ok(()),
        }
    }
    let accept_ok = resp.status() == http::StatusCode::SWITCHING_PROTOCOLS
        && resp.headers().get(http::header::SEC_WEBSOCKET_ACCEPT).map(|v| v.as_bytes())
            == Some(tungstenite::handshake::derive_accept_key(key.as_bytes()).as_bytes());
    if !accept_ok {
        return Err(hs(NetError::new(error::WS_ERROR_PROTOCOL)));
    }
    let upgraded = hyper::upgrade::on(resp).await.map_err(|e| hs(error::from_any(&e, error::CONNECTION_ERROR)))?;
    let mut config = WebSocketConfig::default();
    config = config.max_message_size(Some(d.max_message.max(1))).max_frame_size(Some(d.max_message.max(1)));
    let mut ws = WebSocketStream::from_raw_socket(TokioIo::new(upgraded), Role::Client, Some(config)).await;

    let tag = st.tag;
    let mut paused = false;
    let mut peer_closed = false;
    let mut ping = d.keepalive.map(|k| {
        let mut i = tokio::time::interval_at(tokio::time::Instant::now() + k, k);
        i.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        i
    });
    let err = |op: u32, e: NetError| (EV_WS_ERROR, op, e);
    enum Wake {
        Cmd(Option<Cmd>),
        Msg(Option<Result<Message, tungstenite::Error>>),
        Resume,
        Ping,
    }
    loop {
        let mut resumed = std::pin::pin!(st.wake.notified());
        let wake = futures_util::future::poll_fn(|cx| {
            use std::task::Poll;
            if let Poll::Ready(c) = rx.poll_recv(cx) {
                return Poll::Ready(Wake::Cmd(c));
            }
            if !paused {
                if let Poll::Ready(m) = ws.poll_next_unpin(cx) {
                    return Poll::Ready(Wake::Msg(m));
                }
            } else if resumed.as_mut().poll(cx).is_ready() {
                return Poll::Ready(Wake::Resume);
            }
            if let (Some(p), false) = (ping.as_mut(), peer_closed) {
                if p.poll_tick(cx).is_ready() {
                    return Poll::Ready(Wake::Ping);
                }
            }
            Poll::Pending
        })
        .await;
        match wake {
            Wake::Cmd(cmd) => match cmd {
                None => return Ok(()), // aborted
                Some(Cmd::Accept) => {}
                Some(Cmd::Send { binary, data }) => {
                    let n = data.len() as u64;
                    let msg = if binary {
                        Message::Binary(Bytes::from(data))
                    } else {
                        match Utf8Bytes::try_from(data) {
                            Ok(t) => Message::Text(t),
                            Err(_) => return Err(err(OP_SEND, NetError::new(error::WS_ERROR_INVALID_UTF8))),
                        }
                    };
                    ws.send(msg).await.map_err(|e| err(OP_SEND, ws_error(&e)))?;
                    inner.push(Ev { kind: EV_WS_WRITE_DONE, tag, n, ..Default::default() });
                }
                Some(Cmd::Shutdown { code, reason }) => {
                    if !peer_closed {
                        let frame = (code != 1005).then(|| CloseFrame {
                            code: CloseCode::from(code),
                            reason: Utf8Bytes::try_from(reason).unwrap_or_else(|_| Utf8Bytes::from_static("")),
                        });
                        ws.close(frame).await.map_err(|e| err(OP_SHUTDOWN, ws_error(&e)))?;
                    } else {
                        // tungstenite answered the peer's close frame with the same code already
                        let _ = ws.flush().await;
                    }
                    inner.push(Ev { kind: EV_WS_SHUTDOWN_DONE, tag, ..Default::default() });
                }
            },
            Wake::Msg(msg) => match msg {
                None => return Err(err(OP_RECEIVE, NetError::new(error::CONNECTION_ERROR))),
                Some(Err(e)) => return Err(err(OP_RECEIVE, ws_error(&e))),
                Some(Ok(m)) => {
                    let (btype, data) = match m {
                        Message::Text(t) => (UTF8_MESSAGE, Bytes::from(t).to_vec()),
                        Message::Binary(b) => (BINARY_MESSAGE, b.to_vec()),
                        Message::Close(f) => {
                            peer_closed = true;
                            let (code, reason) = match f {
                                Some(f) => (u16::from(f.code) as u32, f.reason.as_bytes().to_vec()),
                                None => (1005, Vec::new()),
                            };
                            inner.push(Ev { kind: EV_WS_PEER_CLOSE, tag, code, data: reason, ..Default::default() });
                            continue;
                        }
                        _ => continue,
                    };
                    let n = data.len();
                    inner.push(Ev { kind: EV_WS_MESSAGE, tag, btype, data, ..Default::default() });
                    if st.queued.fetch_add(n, Ordering::AcqRel) + n >= d.high_water {
                        paused = true;
                    }
                }
            },
            Wake::Resume => {
                if st.queued.load(Ordering::Acquire) < d.low_water { paused = false; }
            }
            Wake::Ping => {
                ws.send(Message::Ping(Bytes::new())).await.map_err(|e| err(OP_SEND, ws_error(&e)))?;
            }
        }
    }
}
