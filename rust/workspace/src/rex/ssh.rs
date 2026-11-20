use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};

use crate::{CancellationToken, RuntimeRemoteHost, Scene, WorkspaceError, scene};

const MASTERS: usize = 15; // KWT indexes 1–15. Index 0 stays available for existing host traffic.
const SESSIONS_PER_MASTER: u8 = 8;

type Usage = Mutex<[u8; MASTERS]>;

#[derive(Default)]
pub(crate) struct Connections(Mutex<HashMap<String, Weak<Usage>>>);

struct Slot {
    usage: Arc<Usage>,
    index: usize,
}

impl Connections {
    fn reserve(&self, route: &str) -> Result<Slot, WorkspaceError> {
        let mut routes = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        routes.retain(|_, usage| usage.strong_count() > 0);
        let usage = routes
            .get(route)
            .and_then(Weak::upgrade)
            .unwrap_or_else(|| {
                let usage = Arc::new(Mutex::new([0; MASTERS]));
                routes.insert(route.to_owned(), Arc::downgrade(&usage));
                usage
            });
        drop(routes);
        let index = {
            let mut counts = usage
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let index = counts
                .iter()
                .position(|count| *count < SESSIONS_PER_MASTER)
                .ok_or_else(|| {
                    WorkspaceError::new(
                        "The SSH connections for Rex are full. Close a Rex window and try again.",
                    )
                })?;
            counts[index] += 1;
            index
        };
        Ok(Slot { usage, index })
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        let mut counts = self
            .usage
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        counts[self.index] -= 1;
    }
}

pub(super) struct Connection {
    pub(super) lease: host::SshLease,
    _slot: Slot,
}

impl Connection {
    pub(super) fn acquire(
        scene: &Scene,
        host: &RuntimeRemoteHost,
        snapshot: &host::RemoteTmuxSnapshot,
        host_id: &str,
        prompt_id: u64,
        cancellation: &CancellationToken,
    ) -> Result<Self, WorkspaceError> {
        let slot = scene
            .runtime
            .rex_connections
            .reserve(snapshot.route_identity())?;
        let index = u8::try_from(slot.index + 1).expect("KWT connection index fits in u8");
        let lease = host
            .acquire_rex_lease(snapshot, index, cancellation, |prompt| {
                scene::request_ssh_prompt(scene, host_id, prompt_id, prompt, cancellation, false)
            })
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        Ok(Self { lease, _slot: slot })
    }
}
