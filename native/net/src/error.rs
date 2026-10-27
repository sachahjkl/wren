//! Failures in the vocabulary package net already speaks (WinHTTP's numbers): the fetch layer, the error pages and the
//! diagnostics classify them, whichever stack ran the request.

use std::fmt;

pub const ERROR_BAD_URL: u32 = 1;
pub const ERROR_BODY_TOO_LARGE: u32 = 2;
pub const ERROR_START_FAILED: u32 = 3;
pub const WS_ERROR_MESSAGE_TOO_BIG: u32 = 21;
pub const WS_ERROR_INVALID_UTF8: u32 = 22;
pub const WS_ERROR_PROTOCOL: u32 = 24;
pub const TIMEOUT: u32 = 12002;
pub const NAME_NOT_RESOLVED: u32 = 12007;
pub const CANNOT_CONNECT: u32 = 12029;
pub const CONNECTION_ERROR: u32 = 12030;
pub const INVALID_SERVER_RESPONSE: u32 = 12152;
pub const SECURE_FAILURE: u32 = 12175;
pub const SECURE_CERT_DATE_INVALID: u32 = 12037;
pub const SECURE_CERT_CN_INVALID: u32 = 12038;
pub const SECURE_INVALID_CA: u32 = 12045;

// WINHTTP_CALLBACK_STATUS_FLAG_* (secure_flags)
pub const FLAG_REV_FAILED: u32 = 0x1;
pub const FLAG_INVALID_CERT: u32 = 0x2;
pub const FLAG_CERT_REVOKED: u32 = 0x4;
pub const FLAG_INVALID_CA: u32 = 0x8;
pub const FLAG_CN_INVALID: u32 = 0x10;
pub const FLAG_DATE_INVALID: u32 = 0x20;
pub const FLAG_CHANNEL_ERROR: u32 = 0x8000_0000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NetError {
    pub code: u32,
    pub flags: u32,
}

impl NetError {
    pub const fn new(code: u32) -> NetError {
        NetError { code, flags: 0 }
    }
}

impl fmt::Display for NetError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "network error {} (flags {:#x})", self.code, self.flags)
    }
}

impl std::error::Error for NetError {}

/// A TLS failure: the certificate's problem when there is one.
pub fn from_tls(e: &rustls::Error) -> NetError {
    use rustls::CertificateError as C;
    match e {
        rustls::Error::InvalidCertificate(c) => match c {
            C::UnknownIssuer => NetError { code: SECURE_INVALID_CA, flags: FLAG_INVALID_CA },
            C::NotValidForName | C::NotValidForNameContext { .. } => NetError { code: SECURE_CERT_CN_INVALID, flags: FLAG_CN_INVALID },
            C::Expired | C::ExpiredContext { .. } | C::NotValidYet | C::NotValidYetContext { .. } => {
                NetError { code: SECURE_CERT_DATE_INVALID, flags: FLAG_DATE_INVALID }
            }
            C::Revoked => NetError { code: SECURE_FAILURE, flags: FLAG_CERT_REVOKED },
            C::UnknownRevocationStatus => NetError { code: SECURE_FAILURE, flags: FLAG_REV_FAILED },
            _ => NetError { code: SECURE_FAILURE, flags: FLAG_INVALID_CERT },
        },
        _ => NetError { code: SECURE_FAILURE, flags: FLAG_CHANNEL_ERROR },
    }
}

/// An I/O failure, looking inside for a TLS or our own error first.
pub fn from_io(e: &std::io::Error, otherwise: u32) -> NetError {
    if let Some(inner) = e.get_ref() {
        if let Some(t) = inner.downcast_ref::<rustls::Error>() {
            return from_tls(t);
        }
        if let Some(n) = inner.downcast_ref::<NetError>() {
            return *n;
        }
    }
    match e.kind() {
        std::io::ErrorKind::TimedOut => NetError::new(TIMEOUT),
        _ => NetError::new(otherwise),
    }
}

/// Walks an error's sources for something we can name.
pub fn from_any(e: &(dyn std::error::Error + 'static), otherwise: u32) -> NetError {
    let mut cur: Option<&(dyn std::error::Error + 'static)> = Some(e);
    let mut parse = false;
    while let Some(x) = cur {
        if let Some(n) = x.downcast_ref::<NetError>() {
            return *n;
        }
        if let Some(t) = x.downcast_ref::<rustls::Error>() {
            return from_tls(t);
        }
        if let Some(io) = x.downcast_ref::<std::io::Error>() {
            if io.get_ref().is_some() {
                let n = from_io(io, otherwise);
                if n.code != otherwise { return n; }
            }
            if io.kind() == std::io::ErrorKind::TimedOut { return NetError::new(TIMEOUT); }
        }
        if let Some(h) = x.downcast_ref::<hyper::Error>() {
            if h.is_parse() || h.is_parse_status() {
                parse = true;
            }
            if h.is_timeout() {
                return NetError::new(TIMEOUT);
            }
        }
        cur = x.source();
    }
    NetError::new(if parse { INVALID_SERVER_RESPONSE } else { otherwise })
}
