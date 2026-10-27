//! HTTP/3 (quinn + h3), only where it can do no harm:
//!   * an origin is tried over QUIC once it announced h3 (Alt-Svc, on the same host) in a response that came over TCP;
//!   * QUIC gets `network.http3.race_ms` to set up its connection; past that the request goes over TCP at once, and the
//!     QUIC handshake goes on in the background for the next requests (Happy Eyeballs between protocols, as Chrome's);
//!   * an origin where QUIC failed (no UDP through a firewall, a handshake error) is left to TCP for
//!     `network.http3.broken_host_ms`. WinHTTP tried QUIC first and never fell back: odin-lang.org stayed on Connecting.
//! One connection per origin, shared by its requests (HTTP/3 multiplexes them).

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use bytes::{Buf, Bytes};
use futures_util::future::{BoxFuture, FutureExt, Shared as SharedFut};

use crate::conn::{self, ConnInfo};
use crate::error::{self, NetError};
use crate::Shared;

type Sender = h3::client::SendRequest<h3_quinn::OpenStreams, Bytes>;
type Connecting = SharedFut<BoxFuture<'static, Result<(Sender, ConnInfo), NetError>>>;

struct State {
    alt: HashMap<String, (u16, Instant)>, // origin "host:port" -> (h3 port, expiry)
    broken: HashMap<String, Instant>,     // origin -> QUIC left alone until
    conns: HashMap<String, (u64, Connecting)>,
    next: u64,
}

pub(crate) struct H3 {
    shared: Arc<Shared>,
    state: Arc<Mutex<State>>,
    v4: OnceLock<Option<quinn::Endpoint>>,
    v6: OnceLock<Option<quinn::Endpoint>>,
}

pub(crate) enum Outcome {
    Sent((http::Response<()>, H3Body, ConnInfo)),
    UseTcp,
    Failed(NetError),
}

pub(crate) struct H3Body {
    stream: h3::client::RequestStream<h3_quinn::BidiStream<Bytes>, Bytes>,
}

impl H3Body {
    pub async fn next(&mut self) -> Result<Option<Bytes>, NetError> {
        match self.stream.recv_data().await {
            Ok(Some(mut b)) => Ok(Some(b.copy_to_bytes(b.remaining()))),
            Ok(None) => Ok(None),
            Err(_) => Err(NetError::new(error::CONNECTION_ERROR)),
        }
    }
}

fn origin_key(uri: &http::Uri) -> Option<String> {
    Some(format!("{}:{}", conn::bare_host(uri)?.to_ascii_lowercase(), conn::default_port(uri)))
}

/// The h3 alternative of an Alt-Svc value on the same host: its port and lifetime. `None` for "clear".
pub(crate) fn parse_alt_svc(v: &str) -> Option<Option<(u16, Duration)>> {
    if v.trim().eq_ignore_ascii_case("clear") {
        return Some(None);
    }
    for entry in v.split(',') {
        let mut parts = entry.split(';');
        let Some((proto, authority)) = parts.next().and_then(|p| p.trim().split_once('=')) else { continue };
        if proto.trim() != "h3" { continue; }
        let authority = authority.trim().trim_matches('"');
        let Some((host, port)) = authority.rsplit_once(':') else { continue };
        if !host.is_empty() { continue; } // another host: not followed
        let Ok(port) = port.parse::<u16>() else { continue };
        let mut ma = 86_400u64;
        for p in parts {
            if let Some((k, val)) = p.trim().split_once('=') {
                if k.trim().eq_ignore_ascii_case("ma") {
                    ma = val.trim().trim_matches('"').parse().unwrap_or(ma);
                }
            }
        }
        return Some(Some((port, Duration::from_secs(ma))));
    }
    None
}

impl H3 {
    pub fn new(shared: Arc<Shared>) -> H3 {
        H3 {
            shared,
            state: Arc::new(Mutex::new(State { alt: HashMap::new(), broken: HashMap::new(), conns: HashMap::new(), next: 1 })),
            v4: OnceLock::new(),
            v6: OnceLock::new(),
        }
    }

    pub fn clear(&self) {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        st.conns.clear();
        st.alt.clear();
    }

    pub fn note_alt_svc(&self, url: &str, value: &str) {
        let Ok(uri) = url.parse::<http::Uri>() else { return };
        if uri.scheme_str() != Some("https") { return; }
        let Some(key) = origin_key(&uri) else { return };
        let Some(alt) = parse_alt_svc(value) else { return };
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        match alt {
            Some((port, ma)) => {
                st.alt.insert(key, (port, Instant::now() + ma));
            }
            None => {
                st.alt.remove(&key);
            }
        }
    }

    /// The h3 port to try for this origin, if any.
    pub fn candidate(&self, uri: &http::Uri) -> Option<u16> {
        let key = origin_key(uri)?;
        let now = Instant::now();
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(&until) = st.broken.get(&key) {
            if until > now { return None; }
            st.broken.remove(&key);
        }
        match st.alt.get(&key) {
            Some(&(port, exp)) if exp > now => Some(port),
            Some(_) => {
                st.alt.remove(&key);
                None
            }
            None => None,
        }
    }

    fn endpoint(&self, v6: bool) -> Option<quinn::Endpoint> {
        let cell = if v6 { &self.v6 } else { &self.v4 };
        cell.get_or_init(|| {
            let bind: SocketAddr = if v6 { "[::]:0".parse().unwrap() } else { "0.0.0.0:0".parse().unwrap() };
            quinn::Endpoint::client(bind).ok()
        })
        .clone()
    }

    fn mark_broken(state: &Mutex<State>, key: &str, for_: Duration) {
        let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
        st.broken.insert(key.to_string(), Instant::now() + for_);
        st.conns.remove(key);
    }

    fn drop_conn(state: &Mutex<State>, key: &str, id: u64) {
        let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
        if st.conns.get(key).map(|c| c.0) == Some(id) {
            st.conns.remove(key);
        }
    }

    /// The origin's connection: the one being made or made, else a new one (made in its own task: it goes on when the
    /// request that started it went over TCP).
    fn connection(&self, key: &str, host: &str, port: u16) -> (u64, Connecting, bool) {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((id, c)) = st.conns.get(key) {
            return (*id, c.clone(), false);
        }
        let id = st.next;
        st.next += 1;
        let shared = self.shared.clone();
        let state = self.state.clone();
        let (key_s, host_s) = (key.to_string(), host.to_string());
        let eps = (self.endpoint(false), self.endpoint(true));
        let task = tokio::spawn(async move {
            let r = connect(&shared, eps, &host_s, port, state.clone(), key_s.clone(), id).await;
            if r.is_err() {
                H3::mark_broken(&state, &key_s, shared.settings().h3_broken);
            }
            r
        });
        let fut: Connecting = async move { task.await.unwrap_or(Err(NetError::new(error::CANNOT_CONNECT))) }.boxed().shared();
        tokio::spawn(fut.clone().map(|_| ())); // driven to its end whoever waits: `peek` then sees it
        st.conns.insert(key.to_string(), (id, fut.clone()));
        (id, fut, true)
    }

    pub async fn try_send(&self, req: &http::Request<Bytes>, port: u16, race: Duration, idempotent: bool) -> Outcome {
        let Some(key) = origin_key(req.uri()) else { return Outcome::UseTcp };
        let Some(host) = conn::bare_host(req.uri()).map(|h| h.to_string()) else { return Outcome::UseTcp };
        let (id, connecting, new) = self.connection(&key, &host, port);
        // the request that starts the connection gives it the race time; the others take it only once it is up (a QUIC
        // handshake that lost its race must not cost every request of the page that time again)
        let made = if new {
            match futures_util::future::select(connecting, Box::pin(tokio::time::sleep(race))).await {
                futures_util::future::Either::Left((r, _)) => r,
                futures_util::future::Either::Right(_) => return Outcome::UseTcp,
            }
        } else {
            match connecting.peek() {
                Some(r) => r.clone(),
                None => return Outcome::UseTcp,
            }
        };
        let Ok((mut sender, info)) = made else { return Outcome::UseTcp };
        match send(&mut sender, req).await {
            Ok((resp, body)) => Outcome::Sent((resp, body, info)),
            Err(e) => {
                H3::drop_conn(&self.state, &key, id);
                if idempotent { Outcome::UseTcp } else { Outcome::Failed(e) }
            }
        }
    }
}

async fn connect(
    shared: &Shared,
    eps: (Option<quinn::Endpoint>, Option<quinn::Endpoint>),
    host: &str,
    port: u16,
    state: Arc<Mutex<State>>,
    key: String,
    id: u64,
) -> Result<(Sender, ConnInfo), NetError> {
    let s = shared.settings();
    let mut info = ConnInfo::default();
    let addrs = conn::resolve(host, port, s.resolve, &mut info).await?;
    let addr = addrs[0];
    let ep = if addr.is_ipv6() { eps.1 } else { eps.0 }.ok_or(NetError::new(error::CANNOT_CONNECT))?;
    let crypto = quinn::crypto::rustls::QuicClientConfig::try_from(shared.tls_h3.clone()).map_err(|_| NetError::new(error::SECURE_FAILURE))?;
    let mut cfg = quinn::ClientConfig::new(Arc::new(crypto));
    let mut transport = quinn::TransportConfig::default();
    transport.keep_alive_interval(Some(Duration::from_secs(15)));
    if let Ok(idle) = quinn::IdleTimeout::try_from(Duration::from_secs(60)) {
        transport.max_idle_timeout(Some(idle));
    }
    cfg.transport_config(Arc::new(transport));
    info.connect_start = Some(Instant::now());
    let handshake = async {
        let connecting = ep.connect_with(cfg, addr, host).map_err(|_| NetError::new(error::CANNOT_CONNECT))?;
        connecting.await.map_err(|e| match e {
            quinn::ConnectionError::TimedOut => NetError::new(error::TIMEOUT),
            quinn::ConnectionError::TransportError(t) => {
                // a TLS alert from the server or our verifier's verdict
                if u64::from(t.code) & 0x100 != 0 { NetError { code: error::SECURE_FAILURE, flags: error::FLAG_CHANNEL_ERROR } }
                else { NetError::new(error::CANNOT_CONNECT) }
            }
            _ => NetError::new(error::CANNOT_CONNECT),
        })
    };
    let qc = match s.connect {
        Some(t) => tokio::time::timeout(t, handshake).await.unwrap_or(Err(NetError::new(error::TIMEOUT)))?,
        None => handshake.await?,
    };
    info.remote = Some(qc.remote_address());
    info.connect_end = Some(Instant::now());
    info.secure_end = info.connect_end;
    let (mut driver, sender) = h3::client::new(h3_quinn::Connection::new(qc)).await.map_err(|_| NetError::new(error::CONNECTION_ERROR))?;
    tokio::spawn(async move {
        let _ = futures_util::future::poll_fn(|cx| driver.poll_close(cx)).await;
        H3::drop_conn(&state, &key, id);
    });
    Ok((sender, info))
}

async fn send(sender: &mut Sender, req: &http::Request<Bytes>) -> Result<(http::Response<()>, H3Body), NetError> {
    let mut head = http::Request::builder().method(req.method().clone()).uri(req.uri().clone()).body(()).map_err(|_| NetError::new(error::ERROR_START_FAILED))?;
    for (n, v) in req.headers() {
        match n.as_str() {
            "connection" | "keep-alive" | "proxy-connection" | "transfer-encoding" | "upgrade" | "host" => {}
            _ => {
                head.headers_mut().append(n.clone(), v.clone());
            }
        }
    }
    let ce = |_| NetError::new(error::CONNECTION_ERROR);
    let mut stream = sender.send_request(head).await.map_err(ce)?;
    if !req.body().is_empty() {
        stream.send_data(req.body().clone()).await.map_err(ce)?;
    }
    stream.finish().await.map_err(ce)?;
    let resp = stream.recv_response().await.map_err(|_| NetError::new(error::INVALID_SERVER_RESPONSE))?;
    Ok((resp, H3Body { stream }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alt_svc() {
        assert_eq!(parse_alt_svc(r#"h3=":443"; ma=86400, h3-29=":443""#), Some(Some((443, Duration::from_secs(86400)))));
        assert_eq!(parse_alt_svc(r#"h3-29=":443", h3=":8443"; ma=60"#), Some(Some((8443, Duration::from_secs(60)))));
        assert_eq!(parse_alt_svc(r#"h3="other.example:443""#), None);
        assert_eq!(parse_alt_svc("clear"), Some(None));
        assert_eq!(parse_alt_svc(r#"h2=":443""#), None);
    }
}
