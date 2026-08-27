//! In-memory scene registry: per-scene secrets established from single-use
//! mint codes, bounded by idle and absolute lifetimes.
//!
//! A scene is the browser-side authority unit. Its secret is minted only
//! from a single-use, seconds-scale mint code (delivered in the bootstrap
//! redirect fragment) — never from the ambient session cookie alone — so a
//! sibling loopback service that captured the cookie holds no scene
//! authority. The secret lives only here in memory and travels only in a
//! request header or the first websocket frame; it is never placed in a
//! cookie or URL.
//!
//! Time is injected as an `Instant` on every call so expiry is exercised
//! deterministically in tests rather than against the wall clock.

use std::collections::HashMap;
use std::io;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tokio::sync::Mutex as AsyncMutex;

/// How long a bootstrap mint code remains redeemable. Seconds-scale: the
/// code is handed to the page in the redirect fragment and exchanged
/// immediately, so a short window bounds a captured code's value.
const MINT_CODE_TTL: Duration = Duration::from_secs(30);

/// Idle bound: a scene expires this long after its last authenticated use.
const SCENE_IDLE_TIMEOUT: Duration = Duration::from_mins(30);

/// Absolute bound: a scene expires this long after minting regardless of
/// use, forcing a fresh establishment from bootstrap.
const SCENE_ABSOLUTE_LIFETIME: Duration = Duration::from_hours(24);

/// The credential a browser presents for scene-scoped operations.
pub(crate) struct SceneCredential {
    pub(crate) scene_id: String,
    pub(crate) scene_secret: String,
}

struct Scene {
    secret: String,
    minted_at: Instant,
    last_used_at: Instant,
}

impl Scene {
    /// A scene is live only while it is within BOTH bounds. Either bound
    /// alone expires it.
    fn is_live(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.last_used_at) <= SCENE_IDLE_TIMEOUT
            && now.saturating_duration_since(self.minted_at) <= SCENE_ABSOLUTE_LIFETIME
    }
}

#[derive(Default)]
struct Registry {
    /// Redeemable mint codes and their expiry. A code is removed on the
    /// first redemption attempt, success or not.
    mint_codes: HashMap<String, Instant>,
    scenes: HashMap<String, Scene>,
    /// Per-scene attachment serialization: a scene's replacement waits for
    /// its own predecessor's teardown, but scenes never block each other.
    serials: HashMap<String, Arc<AsyncMutex<()>>>,
}

/// The live scene registry. All state is in memory and dies with the
/// server.
pub(crate) struct SceneRegistry {
    inner: Mutex<Registry>,
}

impl SceneRegistry {
    pub(crate) fn new() -> Self {
        Self {
            inner: Mutex::new(Registry::default()),
        }
    }

    /// Mint one single-use bootstrap code, redeemable until `now +
    /// MINT_CODE_TTL`.
    ///
    /// # Errors
    ///
    /// Fails when the operating system entropy source is unavailable.
    pub(crate) fn mint_code(&self, now: Instant) -> io::Result<String> {
        let code = random_hex()?;
        let mut registry = self.lock();
        registry.sweep(now);
        registry
            .mint_codes
            .insert(code.clone(), now + MINT_CODE_TTL);
        Ok(code)
    }

    /// Redeem a mint code for a fresh scene credential. The code is
    /// consumed on this attempt whether or not it was still valid, so a
    /// captured code cannot be retried.
    ///
    /// # Errors
    ///
    /// Fails when the operating system entropy source is unavailable while
    /// minting the new scene. Returns `Ok(None)` for an unknown or expired
    /// code.
    pub(crate) fn redeem(&self, code: &str, now: Instant) -> io::Result<Option<SceneCredential>> {
        let mut registry = self.lock();
        registry.sweep(now);
        // Single-use: remove regardless of validity so a replay of the
        // same code finds nothing.
        let Some(expires_at) = registry.mint_codes.remove(code) else {
            return Ok(None);
        };
        if now > expires_at {
            return Ok(None);
        }
        drop(registry);

        let scene_id = random_hex()?;
        let secret = random_hex()?;
        let mut registry = self.lock();
        registry.scenes.insert(
            scene_id.clone(),
            Scene {
                secret: secret.clone(),
                minted_at: now,
                last_used_at: now,
            },
        );
        Ok(Some(SceneCredential {
            scene_id,
            scene_secret: secret,
        }))
    }

    /// Establish a scene directly from the startup bearer credential, for
    /// non-browser clients that never pass through the bootstrap flow.
    ///
    /// # Errors
    ///
    /// Fails when the operating system entropy source is unavailable.
    pub(crate) fn establish_direct(&self, now: Instant) -> io::Result<SceneCredential> {
        let scene_id = random_hex()?;
        let secret = random_hex()?;
        let mut registry = self.lock();
        registry.sweep(now);
        registry.scenes.insert(
            scene_id.clone(),
            Scene {
                secret: secret.clone(),
                minted_at: now,
                last_used_at: now,
            },
        );
        Ok(SceneCredential {
            scene_id,
            scene_secret: secret,
        })
    }

    /// Validate a presented scene credential in constant time and, on
    /// success, refresh the idle clock. Expiry is refreshed only here — on
    /// a successful authenticated use — never on a failed match.
    pub(crate) fn validate(&self, scene_id: &str, scene_secret: &str, now: Instant) -> bool {
        let mut registry = self.lock();
        let Some(scene) = registry.scenes.get(scene_id) else {
            return false;
        };
        if !scene.is_live(now) {
            registry.scenes.remove(scene_id);
            return false;
        }
        if !constant_time_eq(scene.secret.as_bytes(), scene_secret.as_bytes()) {
            return false;
        }
        registry
            .scenes
            .get_mut(scene_id)
            .expect("scene was just read under the lock")
            .last_used_at = now;
        true
    }

    /// Refresh a live scene's idle clock on authenticated client activity
    /// (a websocket data frame), returning whether it is still live. An
    /// expired scene is dropped and reports `false`. Terminal output and
    /// keepalives never call this, so they do not keep an idle scene alive.
    pub(crate) fn refresh(&self, scene_id: &str, now: Instant) -> bool {
        let mut registry = self.lock();
        match registry.scenes.get_mut(scene_id) {
            Some(scene) if scene.is_live(now) => {
                scene.last_used_at = now;
                true
            }
            Some(_) => {
                registry.scenes.remove(scene_id);
                false
            }
            None => false,
        }
    }

    /// Whether a scene is still within its bounds, WITHOUT refreshing the
    /// idle clock — for a periodic deadline check that must let an idle
    /// scene actually expire. An expired scene is dropped.
    pub(crate) fn is_live(&self, scene_id: &str, now: Instant) -> bool {
        let mut registry = self.lock();
        match registry.scenes.get(scene_id) {
            Some(scene) if scene.is_live(now) => true,
            Some(_) => {
                registry.scenes.remove(scene_id);
                false
            }
            None => false,
        }
    }

    /// The attachment serialization lock for one scene, created on first
    /// use. Two attachments in the same scene serialize on it (so a
    /// replacement waits for its predecessor's teardown); attachments in
    /// different scenes hold different locks and never block each other.
    pub(crate) fn serialization_lock(&self, scene_id: &str) -> Arc<AsyncMutex<()>> {
        let mut registry = self.lock();
        Arc::clone(registry.serials.entry(scene_id.to_owned()).or_default())
    }

    /// Permanently drop every scene and mint code. Called on shutdown.
    pub(crate) fn invalidate(&self) {
        let mut registry = self.lock();
        registry.mint_codes.clear();
        registry.scenes.clear();
        registry.serials.clear();
    }

    /// Drop every scene so any bound attachment's next liveness check
    /// fails closed. A test hook for observing deadline enforcement
    /// without waiting out the real idle/absolute bounds.
    pub(crate) fn expire_all(&self) {
        self.lock().scenes.clear();
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Registry> {
        self.inner.lock().expect("scene registry lock poisoned")
    }
}

impl Registry {
    /// Drop expired mint codes and scenes. Cheap and opportunistic — run
    /// on every mutating call so a long-idle server never accumulates dead
    /// entries.
    fn sweep(&mut self, now: Instant) {
        self.mint_codes.retain(|_, expires_at| now <= *expires_at);
        self.scenes.retain(|_, scene| scene.is_live(now));
        // A serialization lock for a scene that is gone is dead weight; an
        // in-flight attachment keeps its own clone regardless.
        self.serials.retain(|id, _| self.scenes.contains_key(id));
    }
}

fn random_hex() -> io::Result<String> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(io::Error::other)?;
    Ok(hex::encode(bytes))
}

/// Byte-wise comparison whose duration does not depend on where the inputs
/// first differ.
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

    fn base() -> Instant {
        Instant::now()
    }

    #[test]
    fn a_minted_code_redeems_once_for_a_scene() {
        let registry = SceneRegistry::new();
        let t = base();
        let code = registry.mint_code(t).expect("mint code");

        let credential = registry
            .redeem(&code, t)
            .expect("redeem")
            .expect("valid code yields a scene");
        assert_eq!(credential.scene_id.len(), 64);
        assert_eq!(credential.scene_secret.len(), 64);
        assert!(registry.validate(&credential.scene_id, &credential.scene_secret, t));

        // Single-use: a replay of the same code finds nothing.
        assert!(registry.redeem(&code, t).expect("redeem").is_none());
    }

    #[test]
    fn a_failed_redeem_still_consumes_the_code() {
        let registry = SceneRegistry::new();
        let t = base();
        let code = registry.mint_code(t).expect("mint code");

        // Redeemed after its TTL: rejected, but consumed.
        let expired = t + MINT_CODE_TTL + Duration::from_secs(1);
        assert!(registry.redeem(&code, expired).expect("redeem").is_none());
        // Even at a valid time now, the code is gone.
        assert!(registry.redeem(&code, t).expect("redeem").is_none());
    }

    #[test]
    fn an_unknown_code_yields_no_scene() {
        let registry = SceneRegistry::new();
        assert!(
            registry
                .redeem("not-a-code", base())
                .expect("redeem")
                .is_none()
        );
    }

    #[test]
    fn a_wrong_secret_never_validates_or_refreshes() {
        let registry = SceneRegistry::new();
        let t = base();
        let code = registry.mint_code(t).expect("mint code");
        let credential = registry.redeem(&code, t).expect("redeem").expect("scene");

        assert!(!registry.validate(&credential.scene_id, "wrong", t));
        assert!(!registry.validate("unknown-scene", &credential.scene_secret, t));
        // The real credential still validates — a failed attempt changed
        // nothing.
        assert!(registry.validate(&credential.scene_id, &credential.scene_secret, t));
    }

    #[test]
    fn a_scene_expires_on_the_idle_bound_and_use_refreshes_it() {
        let registry = SceneRegistry::new();
        let t = base();
        let code = registry.mint_code(t).expect("mint code");
        let credential = registry.redeem(&code, t).expect("redeem").expect("scene");

        // Use just before the idle bound refreshes the clock.
        let near_idle = t + SCENE_IDLE_TIMEOUT.saturating_sub(Duration::from_secs(1));
        assert!(registry.validate(&credential.scene_id, &credential.scene_secret, near_idle));

        // Another near-idle span from the refreshed point is still live.
        let refreshed = near_idle + SCENE_IDLE_TIMEOUT.saturating_sub(Duration::from_secs(1));
        assert!(registry.validate(&credential.scene_id, &credential.scene_secret, refreshed));

        // Past the idle bound from the last use, it is gone.
        let idle_out = refreshed + SCENE_IDLE_TIMEOUT + Duration::from_secs(1);
        assert!(!registry.validate(&credential.scene_id, &credential.scene_secret, idle_out));
    }

    #[test]
    fn a_scene_expires_on_the_absolute_bound_despite_use() {
        let registry = SceneRegistry::new();
        let t = base();
        let code = registry.mint_code(t).expect("mint code");
        let credential = registry.redeem(&code, t).expect("redeem").expect("scene");

        // Kept warm across the whole day at sub-idle intervals.
        let mut moment = t;
        let step = SCENE_IDLE_TIMEOUT.saturating_sub(Duration::from_mins(1));
        while moment.saturating_duration_since(t) < SCENE_ABSOLUTE_LIFETIME {
            assert!(registry.validate(&credential.scene_id, &credential.scene_secret, moment));
            moment += step;
        }
        // Just past the absolute lifetime, active use cannot save it.
        let absolute_out = t + SCENE_ABSOLUTE_LIFETIME + Duration::from_secs(1);
        assert!(!registry.validate(&credential.scene_id, &credential.scene_secret, absolute_out));
    }

    #[test]
    fn direct_establishment_needs_no_code() {
        let registry = SceneRegistry::new();
        let t = base();
        let credential = registry.establish_direct(t).expect("establish");
        assert!(registry.validate(&credential.scene_id, &credential.scene_secret, t));
    }

    #[test]
    fn refresh_extends_the_idle_clock_but_is_live_does_not() {
        let registry = SceneRegistry::new();
        let t = base();
        let code = registry.mint_code(t).expect("mint code");
        let c = registry.redeem(&code, t).expect("redeem").expect("scene");

        // is_live near the idle bound reports live but does NOT refresh, so
        // the scene still expires on schedule.
        let near = t + SCENE_IDLE_TIMEOUT.saturating_sub(Duration::from_secs(1));
        assert!(registry.is_live(&c.scene_id, near));
        let idle_out = t + SCENE_IDLE_TIMEOUT + Duration::from_secs(1);
        assert!(!registry.is_live(&c.scene_id, idle_out));
    }

    #[test]
    fn refresh_keeps_a_scene_alive_across_activity() {
        let registry = SceneRegistry::new();
        let t = base();
        let code = registry.mint_code(t).expect("mint code");
        let c = registry.redeem(&code, t).expect("redeem").expect("scene");

        let near = t + SCENE_IDLE_TIMEOUT.saturating_sub(Duration::from_secs(1));
        assert!(registry.refresh(&c.scene_id, near));
        // Refreshed: another near-idle span is still live.
        let again = near + SCENE_IDLE_TIMEOUT.saturating_sub(Duration::from_secs(1));
        assert!(registry.is_live(&c.scene_id, again));

        // Past the idle bound from the last refresh, both report expired.
        let out = again + SCENE_IDLE_TIMEOUT + Duration::from_secs(1);
        assert!(!registry.refresh(&c.scene_id, out));
        assert!(!registry.is_live(&c.scene_id, out));
    }

    #[test]
    fn invalidation_drops_every_scene_and_code() {
        let registry = SceneRegistry::new();
        let t = base();
        let code = registry.mint_code(t).expect("mint code");
        let credential = registry.redeem(&code, t).expect("redeem").expect("scene");
        let live_code = registry.mint_code(t).expect("mint code");

        registry.invalidate();

        assert!(!registry.validate(&credential.scene_id, &credential.scene_secret, t));
        assert!(registry.redeem(&live_code, t).expect("redeem").is_none());
    }
}
