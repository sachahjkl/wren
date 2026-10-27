//! Opening a connection: the system resolver, TCP to the addresses in turn (a new attempt every 250 ms while the earlier
//! ones are still trying, RFC 8305's "Happy Eyeballs" without its DNS race), the system proxy (a CONNECT tunnel for
//! https and WebSockets, the absolute form for plain http), then TLS with ALPN.

use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use futures_util::future::Either;
use futures_util::stream::{FuturesUnordered, StreamExt};
use hyper::Uri;
use hyper_util::client::legacy::connect::{Connected, Connection};
use hyper_util::rt::TokioIo;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::TcpStream;

use crate::error::{self, NetError};
use crate::Shared;

/// How the connection was made, handed to each response that used it (hyper-util's "extra" connection info).
#[derive(Clone, Debug, Default)]
pub(crate) struct ConnInfo {
    pub remote: Option<SocketAddr>,
    pub dns_start: Option<Instant>,
    pub dns_end: Option<Instant>,
    pub connect_start: Option<Instant>,
    pub connect_end: Option<Instant>,
    pub secure_end: Option<Instant>,
}

pub(crate) enum Stream {
    Tcp(TcpStream),
    Tls(Box<tokio_rustls::client::TlsStream<TcpStream>>),
}

impl AsyncRead for Stream {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Stream::Tcp(s) => Pin::new(s).poll_read(cx, buf),
            Stream::Tls(s) => Pin::new(s.as_mut()).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Stream {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        match self.get_mut() {
            Stream::Tcp(s) => Pin::new(s).poll_write(cx, buf),
            Stream::Tls(s) => Pin::new(s.as_mut()).poll_write(cx, buf),
        }
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Stream::Tcp(s) => Pin::new(s).poll_flush(cx),
            Stream::Tls(s) => Pin::new(s.as_mut()).poll_flush(cx),
        }
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Stream::Tcp(s) => Pin::new(s).poll_shutdown(cx),
            Stream::Tls(s) => Pin::new(s.as_mut()).poll_shutdown(cx),
        }
    }
    fn poll_write_vectored(self: Pin<&mut Self>, cx: &mut Context<'_>, bufs: &[io::IoSlice<'_>]) -> Poll<io::Result<usize>> {
        match self.get_mut() {
            Stream::Tcp(s) => Pin::new(s).poll_write_vectored(cx, bufs),
            Stream::Tls(s) => Pin::new(s.as_mut()).poll_write_vectored(cx, bufs),
        }
    }
    fn is_write_vectored(&self) -> bool {
        match self {
            Stream::Tcp(s) => s.is_write_vectored(),
            Stream::Tls(s) => s.is_write_vectored(),
        }
    }
}

/// A connection as hyper takes it.
pub(crate) struct Conn {
    pub io: TokioIo<Stream>,
    pub h2: bool,
    pub proxied: bool, // plain http through a proxy: requests go out in absolute form
    pub info: ConnInfo,
}

impl hyper::rt::Read for Conn {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: hyper::rt::ReadBufCursor<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().io).poll_read(cx, buf)
    }
}

impl hyper::rt::Write for Conn {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().io).poll_write(cx, buf)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().io).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().io).poll_shutdown(cx)
    }
    fn is_write_vectored(&self) -> bool {
        self.io.is_write_vectored()
    }
    fn poll_write_vectored(self: Pin<&mut Self>, cx: &mut Context<'_>, bufs: &[io::IoSlice<'_>]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().io).poll_write_vectored(cx, bufs)
    }
}

impl Connection for Conn {
    fn connected(&self) -> Connected {
        let c = Connected::new().proxy(self.proxied).extra(self.info.clone());
        if self.h2 { c.negotiated_h2() } else { c }
    }
}

/// The HTTP client's connector (ALPN h2 + http/1.1, or http/1.1 only when HTTP/2 is turned off).
#[derive(Clone)]
pub(crate) struct Connector {
    pub shared: Arc<Shared>,
}

impl tower_service::Service<Uri> for Connector {
    type Response = Conn;
    type Error = NetError;
    type Future = Pin<Box<dyn Future<Output = Result<Conn, NetError>> + Send>>;

    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<Result<(), NetError>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, uri: Uri) -> Self::Future {
        let shared = self.shared.clone();
        Box::pin(async move {
            let h2 = shared.settings().http2;
            let key = crate::origin_of(&uri);
            shared.track_start(&key);
            let r = connect(&shared, &uri, if h2 { Alpn::H2 } else { Alpn::H1 }).await;
            shared.track_end(&key, r.is_ok());
            r
        })
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Alpn {
    H2,
    H1,
    /// a WebSocket: http/1.1, and a proxy is always tunnelled through
    Ws,
}

/// "host" without the brackets of an IPv6 literal.
pub(crate) fn bare_host(uri: &Uri) -> Option<&str> {
    let h = uri.host()?;
    Some(h.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(h))
}

pub(crate) fn default_port(uri: &Uri) -> u16 {
    uri.port_u16().unwrap_or(if matches!(uri.scheme_str(), Some("https") | Some("wss")) { 443 } else { 80 })
}

async fn with_timeout<T>(d: Option<Duration>, f: impl Future<Output = Result<T, NetError>>) -> Result<T, NetError> {
    match d {
        Some(d) => tokio::time::timeout(d, f).await.unwrap_or(Err(NetError::new(error::TIMEOUT))),
        None => f.await,
    }
}

pub(crate) async fn resolve(host: &str, port: u16, timeout: Option<Duration>, info: &mut ConnInfo) -> Result<Vec<SocketAddr>, NetError> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(vec![SocketAddr::new(ip, port)]);
    }
    info.dns_start = Some(Instant::now());
    let host = host.to_string();
    let addrs = with_timeout(timeout, async move {
        // a resolver may answer "try again" (WSATRY_AGAIN, EAI_AGAIN) for a name it is still asking about: once more
        for attempt in 0..2 {
            match tokio::net::lookup_host((host.as_str(), port)).await {
                Ok(a) => return Ok(a.collect::<Vec<_>>()),
                Err(_) if attempt == 0 => tokio::time::sleep(Duration::from_millis(100)).await,
                Err(_) => {}
            }
        }
        Err(NetError::new(error::NAME_NOT_RESOLVED))
    })
    .await?;
    info.dns_end = Some(Instant::now());
    if addrs.is_empty() {
        return Err(NetError::new(error::NAME_NOT_RESOLVED));
    }
    Ok(order(addrs))
}

/// Interleaves the families, keeping the resolver's preference for the first.
fn order(addrs: Vec<SocketAddr>) -> Vec<SocketAddr> {
    let Some(first) = addrs.first().map(|a| a.is_ipv6()) else { return addrs };
    let (mut a, mut b): (Vec<_>, Vec<_>) = addrs.into_iter().partition(|x| x.is_ipv6() == first);
    let mut out = Vec::with_capacity(a.len() + b.len());
    a.reverse();
    b.reverse();
    loop {
        match (a.pop(), b.pop()) {
            (None, None) => return out,
            (x, y) => {
                out.extend(x);
                out.extend(y);
            }
        }
    }
}

pub(crate) async fn connect_tcp(addrs: Vec<SocketAddr>) -> Result<TcpStream, NetError> {
    const STAGGER: Duration = Duration::from_millis(250);
    let mut it = addrs.into_iter();
    let mut running = FuturesUnordered::new();
    let mut last: Option<io::Error> = None;
    loop {
        if let Some(a) = it.next() {
            running.push(TcpStream::connect(a));
        }
        if running.is_empty() {
            return Err(match last {
                Some(e) if e.kind() == io::ErrorKind::TimedOut => NetError::new(error::TIMEOUT),
                _ => NetError::new(error::CANNOT_CONNECT),
            });
        }
        let r = if it.len() > 0 {
            match futures_util::future::select(running.next(), Box::pin(tokio::time::sleep(STAGGER))).await {
                Either::Left((r, _)) => r,
                Either::Right(_) => None, // the next address starts while the others go on
            }
        } else {
            running.next().await
        };
        match r {
            Some(Ok(s)) => return Ok(s),
            Some(Err(e)) => last = Some(e),
            None => {}
        }
    }
}

/// CONNECT host:port through an HTTP proxy.
async fn tunnel(tcp: &mut TcpStream, host: &str, port: u16, auth: Option<&http::HeaderValue>, ua: &str) -> Result<(), NetError> {
    let authority = if host.contains(':') { format!("[{host}]:{port}") } else { format!("{host}:{port}") };
    let mut req = format!("CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\nUser-Agent: {ua}\r\n").into_bytes();
    if let Some(a) = auth {
        req.extend_from_slice(b"Proxy-Authorization: ");
        req.extend_from_slice(a.as_bytes());
        req.extend_from_slice(b"\r\n");
    }
    req.extend_from_slice(b"\r\n");
    tcp.write_all(&req).await.map_err(|e| error::from_io(&e, error::CANNOT_CONNECT))?;
    let mut buf = Vec::with_capacity(512);
    let mut chunk = [0u8; 512];
    loop {
        // byte at a time past the head would be safer, but a proxy sends nothing after its answer to CONNECT before we speak
        let n = tcp.read(&mut chunk).await.map_err(|e| error::from_io(&e, error::CANNOT_CONNECT))?;
        if n == 0 { return Err(NetError::new(error::CANNOT_CONNECT)); }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = &buf[..end];
            let line = head.split(|&b| b == b'\n').next().unwrap_or(&[]);
            let ok = line.split(|&b| b == b' ').nth(1).map(|s| s.starts_with(b"2")).unwrap_or(false);
            if !ok || end + 4 != buf.len() { return Err(NetError::new(error::CANNOT_CONNECT)); }
            return Ok(());
        }
        if buf.len() > 16 << 10 { return Err(NetError::new(error::INVALID_SERVER_RESPONSE)); }
    }
}

pub(crate) async fn connect(shared: &Shared, uri: &Uri, alpn: Alpn) -> Result<Conn, NetError> {
    let s = shared.settings();
    let secure = matches!(uri.scheme_str(), Some("https") | Some("wss"));
    let host = bare_host(uri).ok_or(NetError::new(error::ERROR_BAD_URL))?.to_string();
    let port = default_port(uri);
    let proxy = if s.proxy_system {
        let probe: Uri = format!("{}://{}/", if secure { "https" } else { "http" }, uri.authority().map(|a| a.as_str()).unwrap_or(""))
            .parse()
            .unwrap_or_else(|_| uri.clone());
        shared.proxy.as_ref().and_then(|m| m.intercept(&probe))
    } else {
        None
    };
    let mut info = ConnInfo::default();
    let (thost, tport) = match &proxy {
        Some(p) => (bare_host(p.uri()).unwrap_or("").to_string(), default_port(p.uri())),
        None => (host.clone(), port),
    };
    let addrs = resolve(&thost, tport, s.resolve, &mut info).await?;
    info.connect_start = Some(Instant::now());
    let fut = async {
        let mut tcp = connect_tcp(addrs).await?;
        let _ = tcp.set_nodelay(true);
        info.remote = tcp.peer_addr().ok();
        info.connect_end = Some(Instant::now());
        let mut proxied = false;
        if let Some(p) = &proxy {
            if secure || alpn == Alpn::Ws {
                tunnel(&mut tcp, &host, port, p.basic_auth(), &s.user_agent).await?;
            } else {
                proxied = true;
            }
        }
        if !secure {
            return Ok(Conn { io: TokioIo::new(Stream::Tcp(tcp)), h2: false, proxied, info: info.clone() });
        }
        let cfg = match alpn {
            Alpn::H2 => shared.tls_h2.clone(),
            Alpn::H1 | Alpn::Ws => shared.tls_h1.clone(),
        };
        let name = rustls::pki_types::ServerName::try_from(host.clone()).map_err(|_| NetError::new(error::ERROR_BAD_URL))?;
        let tls = tokio_rustls::TlsConnector::from(cfg)
            .connect(name, tcp)
            .await
            .map_err(|e| error::from_io(&e, error::SECURE_FAILURE))?;
        let h2 = tls.get_ref().1.alpn_protocol() == Some(b"h2");
        info.secure_end = Some(Instant::now());
        Ok(Conn { io: TokioIo::new(Stream::Tls(Box::new(tls))), h2, proxied, info: info.clone() })
    };
    with_timeout(s.connect, fut).await
}
