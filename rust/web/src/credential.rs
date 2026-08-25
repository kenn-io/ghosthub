//! In-memory startup credentials with constant-time verification.

use std::io;
use std::sync::Mutex;

/// The live secrets: the startup bearer token and the browser session value.
///
/// The two are independent random values. Loopback cookies are visible to
/// every port on the hostname, so the session value stored in the cookie
/// must never equal the bearer token and must never grant bearer access.
struct Secrets {
    token: String,
    session: String,
}

/// The 256-bit startup credentials, hex-encoded and held in memory only.
///
/// Nothing here is ever written to disk or logged. Once invalidated, every
/// subsequent presentation fails; new credentials require a new server.
pub(crate) struct Credential {
    secrets: Mutex<Option<Secrets>>,
}

impl Credential {
    /// Mint fresh credentials from the operating system entropy source.
    pub(crate) fn mint() -> io::Result<(Self, String)> {
        let token = random_hex()?;
        let session = random_hex()?;
        let credential = Self {
            secrets: Mutex::new(Some(Secrets {
                token: token.clone(),
                session,
            })),
        };
        Ok((credential, token))
    }

    /// Compare a presented bearer token against the live credential in
    /// constant time. An invalidated credential matches nothing.
    pub(crate) fn matches_token(&self, presented: &str) -> bool {
        self.matches(presented, |secrets| &secrets.token)
    }

    /// Compare a presented cookie value against the live session value in
    /// constant time. The session value never matches the bearer path.
    pub(crate) fn matches_session(&self, presented: &str) -> bool {
        self.matches(presented, |secrets| &secrets.session)
    }

    fn matches(&self, presented: &str, select: impl Fn(&Secrets) -> &String) -> bool {
        let guard = self.secrets.lock().expect("credential lock poisoned");
        match guard.as_ref() {
            Some(secrets) => constant_time_eq(select(secrets).as_bytes(), presented.as_bytes()),
            None => false,
        }
    }

    /// The value the bootstrap redirect stores in the session cookie.
    pub(crate) fn session_value(&self) -> Option<String> {
        let guard = self.secrets.lock().expect("credential lock poisoned");
        guard.as_ref().map(|secrets| secrets.session.clone())
    }

    /// Permanently invalidate both credentials.
    pub(crate) fn invalidate(&self) {
        *self.secrets.lock().expect("credential lock poisoned") = None;
    }
}

fn random_hex() -> io::Result<String> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(io::Error::other)?;
    Ok(hex::encode(bytes))
}

/// Byte-wise comparison whose duration does not depend on where the inputs
/// first differ. The value length is public, so an early return on length
/// mismatch leaks nothing secret.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter()
        .zip(b)
        .fold(0_u8, |acc, (left, right)| acc | (left ^ right))
        == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mints_a_256_bit_hex_token() {
        let (credential, token) = Credential::mint().expect("mint credential");
        assert_eq!(token.len(), 64);
        assert!(token.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert!(credential.matches_token(&token));
    }

    #[test]
    fn session_value_is_distinct_and_never_grants_bearer_access() {
        let (credential, token) = Credential::mint().expect("mint credential");
        let session = credential.session_value().expect("session value");
        assert_ne!(session, token);
        assert!(credential.matches_session(&session));
        assert!(!credential.matches_token(&session));
        assert!(!credential.matches_session(&token));
    }

    #[test]
    fn rejects_other_tokens() {
        let (credential, token) = Credential::mint().expect("mint credential");
        let mut wrong = token.clone();
        wrong.replace_range(0..1, if token.starts_with('0') { "1" } else { "0" });
        assert!(!credential.matches_token(&wrong));
        assert!(!credential.matches_token(""));
        assert!(!credential.matches_token(&token[..63]));
    }

    #[test]
    fn invalidation_is_permanent() {
        let (credential, token) = Credential::mint().expect("mint credential");
        let session = credential.session_value().expect("session value");
        credential.invalidate();
        assert!(!credential.matches_token(&token));
        assert!(!credential.matches_session(&session));
        assert!(credential.session_value().is_none());
    }

    #[test]
    fn constant_time_eq_agrees_with_equality() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
        assert!(constant_time_eq(b"", b""));
    }
}
