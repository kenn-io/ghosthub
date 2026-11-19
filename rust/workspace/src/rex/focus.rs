use std::collections::BTreeSet;

#[derive(Default)]
pub(super) struct Focus {
    request: Option<(u64, String)>,
    revision: Option<u64>,
}

impl Focus {
    pub(super) fn requested(&self) -> Option<&str> {
        self.request.as_ref().map(|(_, block)| block.as_str())
    }

    pub(super) fn request(&mut self, id: u64, block: String) {
        self.request = Some((id, block));
        self.revision = None;
    }

    pub(super) fn reply(
        &mut self,
        id: u64,
        revision: Option<u64>,
        failed: bool,
        view_revision: Option<u64>,
    ) {
        if self
            .request
            .as_ref()
            .is_none_or(|(latest, _)| *latest != id)
        {
            return;
        }
        if failed {
            self.request = None;
            self.revision = None;
        } else {
            self.revision = Some(revision.unwrap_or(0));
            self.settle(view_revision);
        }
    }

    pub(super) fn view(&mut self, revision: u64, panes: &BTreeSet<String>) {
        if self.requested().is_some_and(|id| !panes.contains(id)) {
            self.request = None;
            self.revision = None;
        }
        self.settle(Some(revision));
    }

    fn settle(&mut self, view_revision: Option<u64>) {
        if self
            .revision
            .zip(view_revision)
            .is_some_and(|(reply, view)| view >= reply)
        {
            self.request = None;
            self.revision = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{BTreeSet, Focus};

    #[test]
    fn rapid_focus_keeps_latest_choice_until_its_view_arrives() {
        let mut focus = Focus::default();
        let panes = BTreeSet::from(["block:a".to_owned(), "block:b".to_owned()]);
        focus.request(1, "block:a".into());
        focus.request(2, "block:b".into());
        focus.request(3, "block:a".into());
        focus.view(10, &panes);
        focus.reply(1, Some(11), false, Some(10));
        focus.reply(2, Some(12), true, Some(10));
        assert_eq!(focus.requested(), Some("block:a"));
        focus.reply(3, Some(13), false, Some(10));
        focus.view(12, &panes);
        assert_eq!(focus.requested(), Some("block:a"));
        focus.view(13, &panes);
        assert_eq!(focus.requested(), None);
    }

    #[test]
    fn current_view_before_reply_settles_and_closed_panes_release_focus() {
        let mut focus = Focus::default();
        let panes = BTreeSet::from(["block:a".to_owned(), "block:b".to_owned()]);
        focus.request(1, "block:b".into());
        focus.view(5, &panes);
        assert_eq!(focus.requested(), Some("block:b"));
        focus.reply(1, Some(5), false, Some(5));
        assert_eq!(focus.requested(), None);
        focus.request(2, "block:b".into());
        focus.view(6, &BTreeSet::from(["block:a".into()]));
        assert_eq!(focus.requested(), None);
        focus.request(3, "block:a".into());
        focus.reply(3, None, true, Some(6));
        assert_eq!(focus.requested(), None);
    }
}
