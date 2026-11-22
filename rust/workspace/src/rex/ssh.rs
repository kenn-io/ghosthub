use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};

use crate::{CancellationToken, RuntimeRemoteHost, Scene, WorkspaceError, scene};

const MASTERS: usize = 15; // KWT indexes 1–15. Index 0 stays available for existing host traffic.
const SESSIONS_PER_MASTER: u8 = 8;

#[derive(Clone, Copy)]
struct Master {
    reserved: u8,
    limit: u8,
}

type Usage = Mutex<[Master; MASTERS]>;

#[derive(Default)]
pub(crate) struct Connections(Mutex<HashMap<String, Weak<Usage>>>);

pub(super) struct Slot {
    usage: Arc<Usage>,
    index: usize,
}

impl Connections {
    pub(super) fn pool(&self, route: &str) -> Pool {
        let mut routes = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        routes.retain(|_, usage| usage.strong_count() > 0);
        let usage = routes
            .get(route)
            .and_then(Weak::upgrade)
            .unwrap_or_else(|| {
                let usage = Arc::new(Mutex::new(
                    [Master {
                        reserved: 0,
                        limit: SESSIONS_PER_MASTER,
                    }; MASTERS],
                ));
                routes.insert(route.to_owned(), Arc::downgrade(&usage));
                usage
            });
        Pool(usage)
    }
}

pub(super) struct Pool(Arc<Usage>);

impl Pool {
    fn reserve(&self) -> Result<Slot, WorkspaceError> {
        let index = {
            let mut counts = self
                .0
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let index = counts
                .iter()
                .position(|master| master.reserved < master.limit)
                .ok_or_else(|| {
                    WorkspaceError::new(
                        "The SSH connections for Rex are full. Close a Rex window and try again.",
                    )
                })?;
            counts[index].reserved += 1;
            index
        };
        Ok(Slot {
            usage: Arc::clone(&self.0),
            index,
        })
    }
}

impl Slot {
    pub(super) fn refused(&self) {
        let mut counts = self
            .usage
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let master = &mut counts[self.index];
        // The refusing reservation will be released with its worker. Keep
        // the remaining reservations on this master and reuse freed slots.
        master.limit = master.limit.min(master.reserved.saturating_sub(1));
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        let mut counts = self
            .usage
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        counts[self.index].reserved -= 1;
    }
}

pub(super) struct Connection {
    pub(super) lease: host::SshLease,
    pub(super) slot: Arc<Slot>,
}

impl Pool {
    pub(super) fn acquire(
        &self,
        scene: &Scene,
        host: &RuntimeRemoteHost,
        snapshot: &host::RemoteTmuxSnapshot,
        host_id: &str,
        prompt_id: u64,
        cancellation: &CancellationToken,
    ) -> Result<Connection, WorkspaceError> {
        let slot = self.reserve()?;
        let index = u8::try_from(slot.index + 1).expect("KWT connection index fits in u8");
        let lease = host
            .acquire_rex_lease(snapshot, index, cancellation, |prompt| {
                scene::request_ssh_prompt(scene, host_id, prompt_id, prompt, cancellation, false)
            })
            .map_err(|error| WorkspaceError::new(error.to_string()))?;
        Ok(Connection {
            lease,
            slot: Arc::new(slot),
        })
    }
}

pub(crate) fn session_refused(code: u32, output: &str) -> bool {
    code == 255 && host::mux_session_refused(output)
}
