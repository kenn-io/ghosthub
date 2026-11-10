use super::*;

#[test]
fn mixed_backend_rows_keep_their_own_lifecycle_actions() {
    let host = HostItem::ssh(
        "studio",
        "Studio",
        "studio.example",
        HostConnectionState::Ready,
        vec![workspace::SessionItem::new("review", 0)],
        None,
    )
    .with_zellij_sessions(vec![workspace::SessionItem::new("review", 0)])
    .with_herdr_sessions(vec![
        workspace::HerdrSessionItem::new("review", false, HerdrSessionState::Running),
        workspace::HerdrSessionItem::new("notes", false, HerdrSessionState::Stopped),
        workspace::HerdrSessionItem::new("default", true, HerdrSessionState::Stopped),
    ]);
    let active = SessionSelection::herdr("studio", "studio.example", "review");
    let rows = sessions(&host, Some(&active), &[], &SidebarPreferences::default());
    let actions: Vec<_> = rows
        .iter()
        .map(|row| {
            (
                row.selection().kind(),
                row.selection().session(),
                row.actions(),
            )
        })
        .collect();
    assert_eq!(
        actions,
        vec![
            (
                workspace::SessionKind::Tmux,
                "review",
                vec![SessionRowAction::KillSession]
            ),
            (
                workspace::SessionKind::Zellij,
                "review",
                vec![SessionRowAction::KillSession]
            ),
            (
                workspace::SessionKind::Herdr,
                "review",
                vec![
                    SessionRowAction::Detach,
                    SessionRowAction::Herdr(HerdrRowAction::Stop)
                ]
            ),
            (
                workspace::SessionKind::Herdr,
                "default",
                vec![SessionRowAction::Herdr(HerdrRowAction::Restart)]
            ),
            (
                workspace::SessionKind::Herdr,
                "notes",
                vec![
                    SessionRowAction::Herdr(HerdrRowAction::Restart),
                    SessionRowAction::Herdr(HerdrRowAction::Delete)
                ]
            ),
        ]
    );
}

#[test]
fn control_tab_remains_representable_when_session_navigation_is_unavailable() {
    for shift in [false, true] {
        let mut key = gpui::Keystroke {
            key: "tab".to_owned(),
            key_char: None,
            modifiers: gpui::Modifiers {
                control: true,
                shift,
                ..gpui::Modifiers::default()
            },
        };
        assert!(terminal_key_input(&key, InputKeyEvent::Press).is_some());
        assert!(terminal_key_input(&key, InputKeyEvent::Release).is_some());
        key.modifiers.control = false;
        assert!(terminal_key_input(&key, InputKeyEvent::Press).is_some());
    }
}

#[test]
fn ordering_and_navigation_cross_backends_and_skip_stopped_sessions() {
    let host = HostItem::ssh(
        "studio",
        "Studio",
        "studio.example",
        HostConnectionState::Ready,
        vec![
            workspace::SessionItem::new("zebra", 0),
            workspace::SessionItem::new("alpha", 0),
        ],
        None,
    )
    .with_zellij_sessions(vec![workspace::SessionItem::new("beta", 0)])
    .with_herdr_sessions(vec![
        workspace::HerdrSessionItem::new("aardvark", false, HerdrSessionState::Stopped),
        workspace::HerdrSessionItem::new("delta", false, HerdrSessionState::Running),
    ]);
    let mut preferences = SidebarPreferences::default();
    let rows = sessions(&host, None, &[], &preferences);
    assert_eq!(
        rows.iter()
            .map(|row| row.selection().session())
            .collect::<Vec<_>>(),
        ["alpha", "zebra", "beta", "delta", "aardvark"]
    );
    assert_eq!(
        adjacent_session(&rows, Some(rows[1].selection()), false)
            .unwrap()
            .kind(),
        workspace::SessionKind::Zellij
    );
    assert_eq!(
        adjacent_session(&rows, Some(rows[3].selection()), false)
            .unwrap()
            .session(),
        "alpha"
    );
    assert_eq!(
        adjacent_session(&rows, Some(rows[0].selection()), true)
            .unwrap()
            .session(),
        "delta"
    );

    preferences.session_sort = SidebarSort::Name;
    let rows = sessions(&host, None, &[], &preferences);
    assert_eq!(
        rows.iter()
            .map(|row| row.selection().session())
            .collect::<Vec<_>>(),
        ["alpha", "beta", "delta", "zebra", "aardvark"]
    );
}

#[test]
fn manual_drag_moves_across_backends_without_moving_same_named_sessions_on_other_hosts() {
    let host = HostItem::ssh(
        "studio",
        "Studio",
        "studio.example",
        HostConnectionState::Ready,
        vec![workspace::SessionItem::new("same", 0)],
        None,
    )
    .with_zellij_sessions(vec![workspace::SessionItem::new("same", 0)]);
    let other = SessionSelection::new("other", "other.example", "same");
    let mut preferences = SidebarPreferences {
        session_order: vec![order_id(&other)],
        ..SidebarPreferences::default()
    };
    let rows = sessions(&host, None, &[], &preferences);
    move_session(
        &mut preferences,
        &rows,
        &order_id(rows[1].selection()),
        &order_id(rows[0].selection()),
    );
    let reordered = sessions(&host, None, &[], &preferences);
    assert_eq!(
        reordered[0].selection().kind(),
        workspace::SessionKind::Zellij
    );
    assert_eq!(
        reordered[1].selection().kind(),
        workspace::SessionKind::Tmux
    );
    assert_eq!(preferences.session_order.first(), Some(&order_id(&other)));
    preferences.session_sort = SidebarSort::Backend;
    move_session(
        &mut preferences,
        &rows,
        &order_id(rows[0].selection()),
        &order_id(rows[1].selection()),
    );
    preferences.session_sort = SidebarSort::Manual;
    assert_eq!(
        sessions(&host, None, &[], &preferences)[0]
            .selection()
            .kind(),
        workspace::SessionKind::Zellij
    );
}

#[test]
fn showing_worktree_sessions_preserves_the_exact_open_and_kill_target() {
    let host = settings::sample_host();
    let mut preferences = SidebarPreferences::default();
    assert!(
        !sessions(&host, None, &[], &preferences)
            .iter()
            .any(|row| row.selection().session() == "atlas/main")
    );
    preferences.hide_worktree_sessions = false;
    let rows = sessions(&host, None, &[], &preferences);
    let row = rows
        .iter()
        .find(|row| row.selection().session() == "atlas/main")
        .expect("visible worktree session");
    assert_eq!(
        row.selection(),
        &SessionSelection::new("preview", "studio.example", "atlas/main")
    );
    assert!(row.can_navigate());
    assert_eq!(row.actions(), [SessionRowAction::KillSession]);
}

#[test]
fn retained_session_navigation_survives_missing_inventory() {
    let host = HostItem::ssh(
        "studio",
        "Studio",
        "studio.example",
        HostConnectionState::Unavailable,
        Vec::new(),
        None,
    );
    let retained = SessionSelection::new("studio", "studio.example", "review");
    let rows = sessions(
        &host,
        None,
        std::slice::from_ref(&retained),
        &SidebarPreferences::default(),
    );
    assert_eq!(adjacent_session(&rows, Some(&retained), false), None);
    let second = SessionSelection::new("studio", "studio.example", "build");
    let rows = sessions(
        &host,
        Some(&retained),
        std::slice::from_ref(&second),
        &SidebarPreferences::default(),
    );
    assert_eq!(
        adjacent_session(&rows, Some(&retained), false),
        Some(second)
    );
    assert_eq!(rows[0].actions(), [] as [SessionRowAction; 0]);
}

#[test]
fn visible_worktree_session_keeps_its_active_presentation_without_a_duplicate_row() {
    let host = settings::sample_host();
    let active = SessionSelection::kwt_workspace(
        "preview",
        "studio.example",
        "atlas/main",
        KwtTmuxAttachMode::Direct,
        None,
        "/projects/atlas",
        None,
    );
    let preferences = SidebarPreferences {
        hide_worktree_sessions: false,
        ..SidebarPreferences::default()
    };
    let rows = sessions(&host, Some(&active), &[], &preferences);
    let matching: Vec<_> = rows
        .iter()
        .filter(|row| row.selection().session() == "atlas/main")
        .collect();
    assert_eq!(matching.len(), 1);
    assert_eq!(matching[0].selection(), &active);
    assert!(matching[0].active());
    assert_eq!(
        matching[0].actions(),
        [SessionRowAction::Detach, SessionRowAction::KillSession]
    );
}

#[test]
fn name_sort_uses_numeric_order_and_a_stable_backend_tie_break() {
    let host = HostItem::ssh(
        "studio",
        "Studio",
        "studio.example",
        HostConnectionState::Ready,
        vec![
            workspace::SessionItem::new("build10", 0),
            workspace::SessionItem::new("build2", 0),
        ],
        None,
    )
    .with_zellij_sessions(vec![workspace::SessionItem::new("Build2", 0)]);
    let preferences = SidebarPreferences {
        session_sort: SidebarSort::Name,
        ..SidebarPreferences::default()
    };
    let rows = sessions(&host, None, &[], &preferences);
    assert_eq!(
        rows.iter()
            .map(|row| (row.selection().session(), row.selection().kind()))
            .collect::<Vec<_>>(),
        [
            ("build2", workspace::SessionKind::Tmux),
            ("Build2", workspace::SessionKind::Zellij),
            ("build10", workspace::SessionKind::Tmux)
        ]
    );
}
