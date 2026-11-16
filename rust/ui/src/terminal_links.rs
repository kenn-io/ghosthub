#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct Hover {
    pub presentation_id: u64,
    pub cell: (usize, usize),
    pub control: bool,
}

struct Click {
    presentation_id: u64,
    cell: (usize, usize),
    target: String,
    dragged: bool,
}

#[derive(Default)]
pub(super) struct TerminalLinks {
    pub hover: Option<Hover>,
    pressed: Option<Click>,
}

fn activation_modifier(modifiers: gpui::Modifiers) -> bool {
    modifiers.control
        && !modifiers.shift
        && !modifiers.alt
        && !modifiers.platform
        && !modifiers.function
}

impl TerminalLinks {
    pub fn observe(
        &mut self,
        presentation_id: u64,
        cell: Option<(usize, usize)>,
        modifiers: gpui::Modifiers,
        left_down: bool,
    ) -> bool {
        let hover = cell.map(|cell| Hover {
            presentation_id,
            cell,
            control: activation_modifier(modifiers),
        });
        let changed = self.hover != hover;
        self.hover = hover;
        if !left_down {
            self.pressed = None;
        } else if let Some(click) = &mut self.pressed {
            click.dragged |= click.presentation_id != presentation_id || Some(click.cell) != cell;
        }
        changed
    }

    pub fn press(
        &mut self,
        presentation_id: u64,
        cell: (usize, usize),
        modifiers: gpui::Modifiers,
        target: Option<&str>,
    ) -> bool {
        self.pressed = None;
        if !activation_modifier(modifiers) {
            return false;
        }
        let Some(target) = target else {
            return false;
        };
        self.pressed = Some(Click {
            presentation_id,
            cell,
            target: target.to_owned(),
            dragged: false,
        });
        true
    }

    pub fn is_pressed(&self) -> bool {
        self.pressed.is_some()
    }

    pub fn release(
        &mut self,
        presentation_id: u64,
        cell: Option<(usize, usize)>,
        modifiers: gpui::Modifiers,
        target: Option<&str>,
    ) -> Option<String> {
        let click = self.pressed.take()?;
        (!click.dragged
            && click.presentation_id == presentation_id
            && Some(click.cell) == cell
            && activation_modifier(modifiers)
            && target == Some(click.target.as_str()))
        .then_some(click.target)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn control() -> gpui::Modifiers {
        gpui::Modifiers {
            control: true,
            ..gpui::Modifiers::default()
        }
    }

    #[test]
    fn only_control_clicks_activate_the_exact_target() {
        let target = "https://example.com/docs?q=one%20two&lang=fr";
        let mut links = TerminalLinks::default();
        for modifiers in [
            gpui::Modifiers::default(),
            gpui::Modifiers {
                shift: true,
                ..control()
            },
            gpui::Modifiers {
                alt: true,
                ..control()
            },
        ] {
            assert!(!links.press(7, (3, 2), modifiers, Some(target)));
        }
        assert!(!links.press(7, (3, 2), control(), None));
        assert!(links.press(7, (3, 2), control(), Some(target)));
        assert_eq!(
            links
                .release(7, Some((3, 2)), control(), Some(target))
                .as_deref(),
            Some(target)
        );
        assert!(
            links
                .release(7, Some((3, 2)), control(), Some(target))
                .is_none()
        );
    }

    #[test]
    fn changed_presentations_destinations_modifiers_and_drags_cancel_opening() {
        for (presentation, cell, modifiers, target) in [
            (8, Some((3, 2)), control(), Some("https://example.com/docs")),
            (7, Some((4, 2)), control(), Some("https://example.com/docs")),
            (7, None, control(), Some("https://example.com/docs")),
            (
                7,
                Some((3, 2)),
                gpui::Modifiers::default(),
                Some("https://example.com/docs"),
            ),
            (
                7,
                Some((3, 2)),
                control(),
                Some("https://example.com/other"),
            ),
            (7, Some((3, 2)), control(), None),
        ] {
            let mut links = TerminalLinks::default();
            assert!(links.press(7, (3, 2), control(), Some("https://example.com/docs")));
            assert!(
                links
                    .release(presentation, cell, modifiers, target)
                    .is_none()
            );
        }
        let mut links = TerminalLinks::default();
        assert!(links.press(7, (3, 2), control(), Some("https://example.com/docs")));
        links.observe(7, Some((4, 2)), control(), true);
        links.observe(7, Some((3, 2)), control(), true);
        assert!(
            links
                .release(7, Some((3, 2)), control(), Some("https://example.com/docs"))
                .is_none()
        );
        assert!(links.press(7, (3, 2), control(), Some("https://example.com/docs")));
        links.observe(7, None, control(), false);
        assert!(!links.is_pressed());
    }
}
