use super::*;
use crate::pump::{event_source_may_have_more, pump_once, retained_event_budget};
use crate::runtime::{
    pending_remote_constructive_target, read_revision_consistent, zellij_kill_revision,
};
use crate::scene::{
    broadcast_event, broadcast_event_with_lossless_owner, push_lossless_event, push_operation_event,
};
use crate::scene::{
    drop_matching_kwt_removal_confirmations, invalidate_pending_kill_with_intent,
    merge_created_inventory, merge_herdr_lifecycle_inventory, publish_attach_inventory,
    publish_attachment_failure, publish_captured_kwt_removal, publish_kwt_error,
    publish_kwt_inventory, publish_kwt_mutation_failure, publish_kwt_project_mutation,
    publish_kwt_removal_capture_failure, publish_legacy_inventory_state, publish_local_notice,
    publish_remote_inventory, publish_retained_stale_failure, publish_stale_attachment_failure,
    reconcile_remote_constructive_with_backoff, reconcile_removed_kwt_worktree,
    reconcile_retained_session_names, reserve_current_constructive_inventory, reserve_kwt_refresh,
    resolve_pending_kwt_creations, resolve_pending_kwt_creations_at, set_inventory_state,
    settle_constructive_inventory, settle_removed_kwt_worktree,
    settle_timed_out_kwt_worktree_remove, tombstone_removed_kwt_worktree,
    with_current_remote_attachment_launch,
};
use terminal::TerminalEngine;

const TEST_REMOTE_ROUTE: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn remote_host_fixture(config: &RemoteTmuxConfig) -> RuntimeRemoteHost {
    let controller =
        KwtSshExecutable::from_absolute(std::env::current_exe().expect("test executable path"))
            .expect("absolute controller path");
    let ssh = SshExecutable::system().expect("system SSH");
    RemoteTmuxHost::new(
        config.clone(),
        &controller,
        &ssh,
        Arc::new(StdCommandRunner),
    )
}

fn remote_herdr_target(name: &str) -> RemoteConstructiveTarget {
    RemoteConstructiveTarget::Herdr {
        route_identity: TEST_REMOTE_ROUTE.to_owned(),
        executable: "/usr/bin/herdr".to_owned(),
        name: name.to_owned(),
        precondition: HerdrLaunchPrecondition::Absent,
    }
}

fn remote_zellij_target(name: &str) -> RemoteConstructiveTarget {
    RemoteConstructiveTarget::Zellij {
        route_identity: TEST_REMOTE_ROUTE.to_owned(),
        executable: "/usr/bin/zellij".to_owned(),
        name: name.to_owned(),
    }
}

#[test]
fn remote_constructive_reconciliation_requires_original_authority() {
    let route = TEST_REMOTE_ROUTE;
    let stopped = session::HerdrSessionRecord::new(
        "agents",
        false,
        HerdrSessionState::Stopped,
        "/srv/herdr/agents",
        "/srv/herdr/agents/herdr.sock",
    );
    let target = RemoteConstructiveTarget::Herdr {
        route_identity: route.to_owned(),
        executable: "/usr/bin/herdr".to_owned(),
        name: "agents".to_owned(),
        precondition: HerdrLaunchPrecondition::Stopped(stopped),
    };
    let matching = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        route,
        7,
        Vec::new(),
        HerdrInventory::Available {
            executable: "/usr/bin/herdr".to_owned(),
            sessions: vec![session::HerdrSessionRecord::new(
                "agents",
                false,
                HerdrSessionState::Running,
                "/srv/herdr/agents",
                "/srv/herdr/agents/herdr.sock",
            )],
        },
        ZellijInventory::Unavailable,
    );
    assert!(remote_constructive_target_is_present(&matching, &target));

    let changed_route = RemoteTmuxSnapshot::test_fixture(
        "replacement.example",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        8,
        Vec::new(),
        matching.herdr().clone(),
        ZellijInventory::Unavailable,
    );
    assert!(!remote_constructive_target_is_present(
        &changed_route,
        &target
    ));

    let changed_executable = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        route,
        8,
        Vec::new(),
        HerdrInventory::Available {
            executable: "/opt/homebrew/bin/herdr".to_owned(),
            sessions: match matching.herdr() {
                HerdrInventory::Available { sessions, .. } => sessions.clone(),
                _ => unreachable!("matching fixture has Herdr inventory"),
            },
        },
        ZellijInventory::Unavailable,
    );
    assert!(!remote_constructive_target_is_present(
        &changed_executable,
        &target
    ));

    let replacement = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        route,
        8,
        Vec::new(),
        HerdrInventory::Available {
            executable: "/usr/bin/herdr".to_owned(),
            sessions: vec![session::HerdrSessionRecord::new(
                "agents",
                false,
                HerdrSessionState::Running,
                "/srv/herdr/replacement",
                "/srv/herdr/replacement/herdr.sock",
            )],
        },
        ZellijInventory::Unavailable,
    );
    assert!(!remote_constructive_target_is_present(
        &replacement,
        &target
    ));
}

#[test]
fn consumed_remote_launch_failure_remains_pending_for_reconciliation() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "",
        None,
    )
    .expect("valid remote host");
    let target = remote_zellij_target("review");
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: None,
                context: None,
                cancellation: None,
                constructive_cancellation: Some(RemoteConstructiveState::Active {
                    scene: workspace.scene.id,
                    navigation_generation: 6,
                    cancellation: CancellationToken::new(),
                    launched: Arc::new(AtomicBool::new(true)),
                    target: target.clone(),
                }),
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );

    let pending = settle_remote_constructive_task(&workspace.scene.runtime, "ssh:studio", 6, false);

    assert_eq!(pending, Some(target.clone()));
    assert_eq!(
        pending_remote_constructive_target(&workspace.scene.runtime, "ssh:studio"),
        Some(target)
    );
}

#[test]
fn remote_zellij_attachment_requires_fresh_executable_and_active_session() {
    let available = ZellijInventory::Available {
        executable: "/opt/homebrew/bin/zellij".to_owned(),
        sessions: vec![session::ZellijSessionRecord::discovered("review")],
    };

    let (executable, session) =
        resolve_remote_zellij_attach_target(&available, "/opt/homebrew/bin/zellij", "review")
            .expect("fresh active session");
    assert_eq!(executable, "/opt/homebrew/bin/zellij");
    assert_eq!(session.name(), "review");
    assert!(resolve_remote_zellij_attach_target(&available, "/usr/bin/zellij", "review").is_err());
    assert!(
        resolve_remote_zellij_attach_target(
            &ZellijInventory::Available {
                executable: "/opt/homebrew/bin/zellij".to_owned(),
                sessions: Vec::new(),
            },
            "/opt/homebrew/bin/zellij",
            "review",
        )
        .is_err()
    );
}

#[test]
fn queued_remote_attachment_recaptures_newer_same_connection_inventory() {
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let host = remote_host_fixture(&config);
    let identity = session::SessionIdentity::new(42, "$1", 100);
    let initial = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        7,
        vec![session::DiscoveredSession::new(
            "build",
            identity.clone(),
            0,
        )],
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );
    let request = RemoteTmuxAttachRequest {
        host_id: config.id().to_owned(),
        connection_generation: 7,
        selection: SessionSelection::new(config.id(), config.endpoint(), "build"),
        host: host.clone(),
        snapshot: initial.clone(),
        session: initial.sessions()[0].clone(),
    };
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            config.id(),
            config.name(),
            config.endpoint(),
            HostConnectionState::Ready,
            vec![SessionItem::new("build", 0)],
            None,
        )],
    ));
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: Some(host.clone()),
                context: Some(RemoteHostContext {
                    generation: 7,
                    host,
                    snapshot: initial.clone(),
                }),
                cancellation: None,
                constructive_cancellation: None,
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );
    let published = publish_remote_inventory(
        &workspace.scene,
        "ssh:studio",
        7,
        &initial,
        &CancellationToken::new(),
        RemoteSessionInventory::test_fixture(
            Some("/usr/bin/tmux".to_owned()),
            vec![
                session::DiscoveredSession::new("build", identity.clone(), 0),
                session::DiscoveredSession::new(
                    "created",
                    session::SessionIdentity::new(42, "$2", 101),
                    0,
                ),
            ],
            HerdrInventory::Unavailable,
            ZellijInventory::Unavailable,
        ),
    )
    .expect("creation publishes newer inventory");

    let recaptured = recapture_remote_tmux_attach_request(&workspace.scene.runtime, &request)
        .expect("queued attachment accepts the newer inventory");

    assert_eq!(recaptured.snapshot.inventory_generation(), 1);
    assert_eq!(
        recaptured.snapshot.inventory_generation(),
        published.inventory_generation()
    );
    assert_eq!(recaptured.session.identity(), &identity);
    assert_eq!(recaptured.snapshot.sessions().len(), 2);
}

#[test]
fn remote_herdr_attachment_requires_fresh_running_identity() {
    let expected = session::HerdrSessionRecord::new(
        "review",
        false,
        HerdrSessionState::Running,
        "/tmp/herdr/review",
        "/tmp/herdr/review.sock",
    );
    let available = HerdrInventory::Available {
        executable: "/usr/local/bin/herdr".to_owned(),
        sessions: vec![expected.clone()],
    };

    let (executable, session) =
        resolve_remote_herdr_attach_target(&available, "/usr/local/bin/herdr", &expected)
            .expect("fresh running session");
    assert_eq!(executable, "/usr/local/bin/herdr");
    assert_eq!(session, expected);

    for replacement in [
        session::HerdrSessionRecord::new(
            "review",
            false,
            HerdrSessionState::Stopped,
            "/tmp/herdr/review",
            "/tmp/herdr/review.sock",
        ),
        session::HerdrSessionRecord::new(
            "review",
            true,
            HerdrSessionState::Running,
            "/tmp/herdr/review",
            "/tmp/herdr/review.sock",
        ),
        session::HerdrSessionRecord::new(
            "review",
            false,
            HerdrSessionState::Running,
            "/tmp/herdr/replacement",
            "/tmp/herdr/replacement.sock",
        ),
    ] {
        assert!(
            resolve_remote_herdr_attach_target(
                &HerdrInventory::Available {
                    executable: "/usr/local/bin/herdr".to_owned(),
                    sessions: vec![replacement],
                },
                "/usr/local/bin/herdr",
                &expected,
            )
            .is_err()
        );
    }
    assert!(resolve_remote_herdr_attach_target(&available, "/usr/bin/herdr", &expected).is_err());
}

#[test]
fn only_remote_tmux_presentations_are_retainable() {
    assert!(retain_remote_session(SessionKind::Tmux));
    assert!(!retain_remote_session(SessionKind::Herdr));
    assert!(!retain_remote_session(SessionKind::Zellij));
}

#[test]
fn project_path_input_accepts_windows_and_wsl_absolute_paths() {
    assert!(is_absolute_project_path_input(r"C:\Users\test\code\widget"));
    assert!(is_absolute_project_path_input("D:/code/widget"));
    assert!(is_absolute_project_path_input(
        r"\\wsl.localhost\Ubuntu\home\test\widget"
    ));
    assert!(is_absolute_project_path_input("/home/test/widget"));
    assert!(!is_absolute_project_path_input(r"C:code\widget"));
    assert!(!is_absolute_project_path_input("code/widget"));
}

#[test]
fn branch_name_validation_matches_the_git_ref_creation_boundary() {
    for valid in ["feature/worktrees", "release-2.0", "users/wes/code"] {
        assert!(
            is_valid_git_branch_name(valid),
            "expected {valid:?} to be valid"
        );
    }
    for invalid in [
        "",
        " feature",
        "feature ",
        "-feature",
        "feature..old",
        "feature@{old}",
        "feature.lock",
        "feature//nested",
        ".hidden/feature",
        "feature?",
    ] {
        assert!(
            !is_valid_git_branch_name(invalid),
            "expected {invalid:?} to be invalid"
        );
    }
}

#[test]
fn worktree_removal_requires_a_canonical_generation() {
    assert!(is_canonical_kwt_generation(
        "0123456789abcdef0123456789ABCDEF"
    ));
    assert!(!is_canonical_kwt_generation("0123456789abcdef"));
    assert!(!is_canonical_kwt_generation(
        "0123456789abcdef0123456789abcdeg"
    ));
}

#[test]
fn worktree_removal_capture_requires_the_reviewed_tmux_socket() {
    let (workspace, _runtime) = kwt_worktree_workspace_fixture();
    let generation = "22222222222222222222222222222222";
    workspace.scene.runtime.hosts.write().expect("hosts")[0].projects[0]
        .worktrees
        .push(WorktreeItem::new(
            "/work/project/protected",
            "protected",
            false,
            Some(generation.to_owned()),
            "project-protected",
            Some("kwt-pr-reviewed".to_owned()),
            false,
        ));

    let captured = capture_kwt_worktree_removal_context(
        &workspace.scene.runtime,
        "wsl",
        "Ubuntu",
        "project-id",
        "/repos/project",
        "project-fingerprint",
        "/work/project/protected",
        generation,
        "project-protected",
        Some("kwt-pr-reviewed"),
    )
    .expect("the reviewed protected socket grants removal capture");
    assert_eq!(captured.3.as_deref(), Some("kwt-pr-reviewed"));

    workspace.scene.runtime.hosts.write().expect("hosts")[0].projects[0].worktrees[1]
        .tmux_socket_name = Some("kwt-pr-replacement".to_owned());
    assert!(
        capture_kwt_worktree_removal_context(
            &workspace.scene.runtime,
            "wsl",
            "Ubuntu",
            "project-id",
            "/repos/project",
            "project-fingerprint",
            "/work/project/protected",
            generation,
            "project-protected",
            Some("kwt-pr-reviewed"),
        )
        .is_err(),
        "a changed protected socket requires a fresh removal confirmation"
    );
}

#[test]
fn later_kwt_inventory_resolves_a_pending_created_worktree_once() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    workspace
        .scene
        .runtime
        .pending_kwt_creations
        .lock()
        .expect("pending creations")
        .push(PendingKwtCreation {
            scene: workspace.scene.id,
            endpoint: snapshot.endpoint().clone(),
            repository: "github.com/acme/widget".to_owned(),
            project_path: "/code/widget".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            branch: "feature/new".to_owned(),
            navigation_generation: 41,
            baseline: Vec::new(),
            refreshes_remaining: PENDING_KWT_CREATION_REFRESH_LIMIT,
            deadline: Instant::now() + PENDING_KWT_CREATION_LIFETIME,
        });
    let inventory = KwtInventory::parse(
            br#"[{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"registration"}]"#,
            br#"[{"path":"/work/widget/new","branch":"feature/new","commit_hash":"abc","is_main":false,"created_at":null,"generation":"0123456789abcdef0123456789abcdef","repository":"github.com/acme/widget","session_name":"widget-new","tmux_socket_name":null}]"#,
            b"[]",
        )
        .expect("valid KWT inventory");

    resolve_pending_kwt_creations(&workspace.scene, snapshot.endpoint(), &inventory);
    resolve_pending_kwt_creations(&workspace.scene, snapshot.endpoint(), &inventory);

    assert!(
        workspace
            .scene
            .runtime
            .pending_kwt_creations
            .lock()
            .expect("pending creations")
            .is_empty()
    );
    let events = workspace
        .scene
        .operation_events
        .lock()
        .expect("operation events");
    assert_eq!(events.len(), 1);
    assert!(matches!(
        events.front().map(|entry| &entry.event),
        Some(WorkspaceEvent::KwtWorktreeCreated {
            target,
            navigation_generation: 41,
        }) if target.worktree_path() == "/work/widget/new"
    ));
}

#[test]
fn pending_creation_ignores_a_preexisting_same_branch_worktree_and_expires() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let baseline = KwtWorktreeIdentity {
        path: "/work/widget/existing".to_owned(),
        generation: Some("0123456789abcdef0123456789abcdef".to_owned()),
    };
    workspace
        .scene
        .runtime
        .pending_kwt_creations
        .lock()
        .expect("pending creations")
        .push(PendingKwtCreation {
            scene: workspace.scene.id,
            endpoint: snapshot.endpoint().clone(),
            repository: "github.com/acme/widget".to_owned(),
            project_path: "/code/widget".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            branch: "feature/new".to_owned(),
            navigation_generation: 42,
            baseline: vec![baseline],
            refreshes_remaining: 2,
            deadline: Instant::now() + Duration::from_mins(1),
        });
    let inventory = KwtInventory::parse(
            br#"[{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"registration"}]"#,
            br#"[{"path":"/work/widget/existing","branch":"feature/new","commit_hash":"def","is_main":false,"created_at":null,"generation":"fedcba9876543210fedcba9876543210","repository":"github.com/acme/widget","session_name":"widget-existing","tmux_socket_name":null}]"#,
            b"[]",
        )
        .expect("valid KWT inventory");

    resolve_pending_kwt_creations(&workspace.scene, snapshot.endpoint(), &inventory);
    assert!(workspace.drain_events().0.is_empty());
    resolve_pending_kwt_creations(&workspace.scene, snapshot.endpoint(), &inventory);

    assert!(matches!(
        workspace.drain_events().0.as_slice(),
        [WorkspaceEvent::KwtWorktreeCreationExpired {
            project_path,
            navigation_generation: 42,
            ..
        }] if project_path == "/code/widget"
    ));
}

#[test]
fn confirmed_creation_expiry_rejects_a_late_same_branch_worktree() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let now = Instant::now();
    workspace
        .scene
        .runtime
        .pending_kwt_creations
        .lock()
        .expect("pending creations")
        .push(PendingKwtCreation {
            scene: workspace.scene.id,
            endpoint: snapshot.endpoint().clone(),
            repository: "github.com/acme/widget".to_owned(),
            project_path: "/code/widget".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            branch: "feature/new".to_owned(),
            navigation_generation: 43,
            baseline: Vec::new(),
            refreshes_remaining: PENDING_KWT_CREATION_REFRESH_LIMIT,
            deadline: now,
        });
    let inventory = KwtInventory::parse(
            br#"[{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"registration"}]"#,
            br#"[{"path":"/work/widget/late","branch":"feature/new","commit_hash":"abc","is_main":false,"created_at":null,"generation":"0123456789abcdef0123456789abcdef","repository":"github.com/acme/widget","session_name":"widget-late","tmux_socket_name":null}]"#,
            b"[]",
        )
        .expect("valid KWT inventory");

    resolve_pending_kwt_creations_at(&workspace.scene, snapshot.endpoint(), &inventory, now);

    assert!(matches!(
        workspace.drain_events().0.as_slice(),
        [WorkspaceEvent::KwtWorktreeCreationExpired {
            navigation_generation: 43,
            ..
        }]
    ));
    resolve_pending_kwt_creations_at(
        &workspace.scene,
        snapshot.endpoint(),
        &inventory,
        now + Duration::from_secs(1),
    );
    assert!(workspace.drain_events().0.is_empty());
}

#[test]
fn worktree_removal_authority_can_be_restored_before_dispatch() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "widget-topic",
            identity.clone(),
            1,
        )],
    );
    let authority = 7;
    workspace
        .scene
        .kwt_removal_generation
        .store(authority, Ordering::Release);
    workspace
        .scene
        .pending_kwt_removal
        .lock()
        .expect("pending removal")
        .replace(PendingKwtRemoval {
            authority,
            endpoint: snapshot.endpoint().clone(),
            repository: "github.com/acme/widget".to_owned(),
            project_path: "/code/widget".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            worktree_path: "/work/widget/topic".to_owned(),
            generation: "0123456789abcdef0123456789abcdef".to_owned(),
            session_name: "widget-topic".to_owned(),
            socket_name: None,
            live_target: Some(Arc::new(host::LiveSessionTarget::test_fixture(
                &snapshot,
                "widget-topic",
                identity.clone(),
            ))),
        });

    let pending = take_pending_kwt_removal(
        &workspace.scene,
        authority,
        "Ubuntu",
        "github.com/acme/widget",
        "/code/widget",
        "registration",
        "/work/widget/topic",
        "0123456789abcdef0123456789abcdef",
        "widget-topic",
    )
    .expect("exact confirmation authority");

    assert_eq!(
        pending
            .live_target
            .as_ref()
            .expect("live authority")
            .identity(),
        &identity
    );
    assert!(
        workspace
            .scene
            .pending_kwt_removal
            .lock()
            .expect("pending removal")
            .is_none()
    );

    restore_pending_kwt_removal(&workspace.scene, pending);
    assert_eq!(
        workspace
            .scene
            .pending_kwt_removal
            .lock()
            .expect("restored pending removal")
            .as_ref()
            .map(|pending| pending.authority),
        Some(authority)
    );
}

#[test]
fn worktree_removal_reservation_requires_the_exact_non_main_inventory_row() {
    let project = ProjectItem::new(
        "github.com/acme/widget",
        "widget",
        "/code/widget",
        "registration",
        vec![
            WorktreeItem::new(
                "/code/widget",
                "main",
                true,
                Some("11111111111111111111111111111111".to_owned()),
                "widget-main",
                None,
                false,
            ),
            WorktreeItem::new(
                "/work/widget/topic",
                "topic",
                false,
                Some("22222222222222222222222222222222".to_owned()),
                "widget-topic",
                None,
                true,
            ),
            WorktreeItem::new(
                "/work/widget/protected",
                "protected",
                false,
                Some("33333333333333333333333333333333".to_owned()),
                "widget-protected",
                Some("protected-socket".to_owned()),
                false,
            ),
        ],
    );
    let remove = |path: &str, generation: &str, session: &str, socket_name: Option<&str>| {
        KwtWorktreeOperation::Remove {
            worktree_path: path.to_owned(),
            generation: generation.to_owned(),
            session_name: session.to_owned(),
            socket_name: socket_name.map(str::to_owned),
            live_target: None,
            operation_id: 1,
        }
    };

    assert!(
        validate_kwt_worktree_operation(
            &project,
            &remove(
                "/work/widget/topic",
                "22222222222222222222222222222222",
                "widget-topic",
                None,
            ),
        )
        .is_ok()
    );
    assert!(
        validate_kwt_worktree_operation(
            &project,
            &remove(
                "/code/widget",
                "11111111111111111111111111111111",
                "widget-main",
                None,
            ),
        )
        .is_err()
    );
    assert!(
        validate_kwt_worktree_operation(
            &project,
            &remove(
                "/work/widget/topic",
                "22222222222222222222222222222222",
                "replacement",
                None,
            ),
        )
        .is_err()
    );
    assert!(
        validate_kwt_worktree_operation(
            &project,
            &remove(
                "/work/widget/protected",
                "33333333333333333333333333333333",
                "widget-protected",
                Some("protected-socket"),
            ),
        )
        .is_ok(),
        "custom-socket worktrees are removable only through their exact protected socket"
    );
}

#[test]
fn killed_tmux_cleanup_matches_worktree_presentations_by_authoritative_name() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let target = AttachTarget::Worktree {
        repository: "project-id".to_owned(),
        registration_fingerprint: "registration".to_owned(),
        path: "/work/project/topic".to_owned(),
        generation: Some("generation".to_owned()),
        session_name: "project-topic".to_owned(),
    };

    assert!(attach_target_matches_killed_tmux(
        &target,
        &identity,
        Some("project-topic"),
        None,
    ));
    assert!(!attach_target_matches_killed_tmux(
        &target,
        &identity,
        Some("replacement"),
        None,
    ));
    assert!(!attach_target_matches_killed_tmux(
        &target, &identity, None, None
    ));
}

#[cfg(windows)]
#[test]
fn worktree_navigation_reuses_the_equivalent_discovered_tmux_identity() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "project-topic",
            identity.clone(),
            1,
        )],
    );
    let direct = attach_request_fixture(&snapshot, identity, "project-topic");
    let mut worktree = direct.clone();
    worktree.target = AttachTarget::Worktree {
        repository: "project-id".to_owned(),
        registration_fingerprint: "registration".to_owned(),
        path: "/work/project/topic".to_owned(),
        generation: Some("generation".to_owned()),
        session_name: "project-topic".to_owned(),
    };

    let key = worktree_tmux_presentation_key(&worktree, &snapshot)
        .expect("the current tmux session supplies a stable presentation key");
    assert_eq!(key, direct.presentation_key());
}

#[cfg(windows)]
#[test]
fn launched_worktree_identity_remains_reusable_after_it_becomes_unbound() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "project-topic",
            identity.clone(),
            1,
        )],
    );
    let direct = attach_request_fixture(&snapshot, identity, "project-topic");
    let mut worktree = direct.clone();
    worktree.target = AttachTarget::Worktree {
        repository: "project-id".to_owned(),
        registration_fingerprint: "registration".to_owned(),
        path: "/work/project/topic".to_owned(),
        generation: Some("generation".to_owned()),
        session_name: "project-topic".to_owned(),
    };
    let worktree_key = worktree.presentation_key();

    let mut active = AttachmentState::new();
    active.reserve_with_fallback(
        worktree,
        AttachTerm::Xterm256Color,
        Some(FallbackAuthority {
            presentation: direct.presentation_key(),
            target: worktree_key,
            navigation_generation: 0,
        }),
    );
    assert!(normalize_attached_worktree_target(
        active.active_mut().expect("active worktree"),
        &snapshot,
        "project-topic",
    ));
    assert_eq!(
        active
            .active()
            .expect("normalized active presentation")
            .request
            .presentation_key(),
        direct.presentation_key(),
    );
    assert_eq!(
        active
            .active()
            .expect("normalized fallback")
            .fallback
            .as_ref()
            .expect("fallback authority")
            .target,
        direct.presentation_key(),
    );

    let active = active.take_active().expect("retain active presentation");
    let key = active.request.presentation_key();
    let mut retained = RetainedPresentations::new();
    retained.insert(RetainedPresentation {
        key: key.clone(),
        selection: active.request.selection(),
        attachment: active,
        worker: (),
        presentation_id: 1,
    });
    assert!(retained.contains(&direct.presentation_key()));
}

#[test]
fn successful_worktree_removal_tombstones_only_the_exact_cached_generation() {
    let mut host = HostItem::wsl("Ubuntu", None, HostConnectionState::Ready, Vec::new(), None);
    host.projects = vec![ProjectItem::new(
        "project-id",
        "project",
        "/repos/project",
        "project-fingerprint",
        vec![
            WorktreeItem::new(
                "/work/project/topic",
                "topic",
                false,
                Some("old-generation".to_owned()),
                "project-topic",
                None,
                false,
            ),
            WorktreeItem::new(
                "/work/project/topic",
                "topic",
                false,
                Some("replacement-generation".to_owned()),
                "project-topic",
                None,
                false,
            ),
        ],
    )];

    assert!(remove_cached_kwt_worktree(
        &mut host,
        "project-id",
        "/repos/project",
        "project-fingerprint",
        "/work/project/topic",
        "old-generation",
    ));
    assert_eq!(host.projects[0].worktrees.len(), 1);
    assert_eq!(
        host.projects[0].worktrees[0].generation(),
        Some("replacement-generation"),
    );
}

#[test]
fn cancelled_removal_capture_cannot_publish_a_late_failure() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    workspace
        .scene
        .kwt_removal_generation
        .store(2, Ordering::Release);

    publish_kwt_removal_capture_failure(
        &workspace.scene,
        1,
        "/code/widget",
        "/work/widget/topic",
        "stale failure".to_owned(),
    );
    assert!(workspace.drain_events().0.is_empty());

    publish_kwt_removal_capture_failure(
        &workspace.scene,
        2,
        "/code/widget",
        "/work/widget/topic",
        "current failure".to_owned(),
    );
    let (events, _) = workspace.drain_events();
    assert!(matches!(
        events.as_slice(),
        [WorkspaceEvent::KwtWorktreeOperationFailed {
            operation_id: 2,
            project_path,
            worktree_path: Some(worktree_path),
            message,
        }] if project_path == "/code/widget"
            && worktree_path == "/work/widget/topic"
            && message == "current failure"
    ));
}

#[cfg(windows)]
#[test]
fn kwt_attachment_failures_preserve_the_fresh_host_snapshot() {
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let AttachFreshError::SessionChanged {
        error,
        snapshot: preserved,
    } = kwt_attachment_failure(&snapshot, "KWT inventory failed")
    else {
        panic!("KWT failures must remain scoped below host transport");
    };

    assert_eq!(error.to_string(), "KWT inventory failed");
    assert_eq!(preserved.endpoint(), snapshot.endpoint());
    assert_eq!(preserved.runtime(), snapshot.runtime());
}

#[test]
fn worktree_startup_rejects_an_early_guard_failure_before_inventory() {
    let cancellation = CancellationToken::new();
    let mut observations = VecDeque::from([
            TerminalStartup::Pending,
            TerminalStartup::Exited {
                code: 1,
                output_tail: r#"{"error":{"code":"registration_changed","message":"the worktree changed","retryable":true}}"#.to_owned(),
            },
        ]);

    let error = wait_for_worktree_client_startup(
        AttachTerm::Xterm256Color,
        &cancellation,
        &[Duration::ZERO, Duration::ZERO],
        || {
            Ok(observations
                .pop_front()
                .expect("one observation per startup attempt"))
        },
        || Ok(None),
    )
    .expect_err("guard rejection must prevent session publication");

    let WorktreeClientStartupError::Failed(error) = error else {
        panic!("a KWT guard rejection is not a terminfo fallback");
    };
    assert!(error.to_string().contains("registration_changed"));
    assert!(observations.is_empty());
}

#[test]
fn worktree_startup_never_accepts_inventory_without_client_confirmation() {
    let cancellation = CancellationToken::new();
    let mut observations = 0;

    let error = wait_for_worktree_client_startup(
        AttachTerm::Xterm256Color,
        &cancellation,
        &[Duration::ZERO; 3],
        || {
            observations += 1;
            Ok(TerminalStartup::Pending)
        },
        || Ok(None),
    )
    .expect_err("a same-named session cannot prove client attachment");

    assert_eq!(observations, 4);
    let WorktreeClientStartupError::Failed(error) = error else {
        panic!("a pending client is not a terminfo fallback");
    };
    assert!(error.to_string().contains("did not establish"));
}

#[test]
fn worktree_startup_retries_only_the_exact_initial_terminfo_failure() {
    let cancellation = CancellationToken::new();
    let error = wait_for_worktree_client_startup(
        AttachTerm::Xterm256Color,
        &cancellation,
        &[],
        || {
            Ok(TerminalStartup::Exited {
                code: 1,
                output_tail:
                    "open terminal failed: missing or unsuitable terminal: xterm-256color\r\n"
                        .to_owned(),
            })
        },
        || Ok(None),
    )
    .expect_err("missing xterm-256color requests the conservative retry");

    assert!(matches!(error, WorktreeClientStartupError::RetryWithXterm));
}

#[test]
fn worktree_startup_uses_stable_tmux_client_identity_without_alt_screen() {
    let cancellation = CancellationToken::new();
    let identity = session::SessionIdentity::new(42, "$7", 99);
    let mut readiness = VecDeque::from([Some(identity.clone()), Some(identity.clone())]);

    let observed = wait_for_worktree_client_startup(
        AttachTerm::Xterm256Color,
        &cancellation,
        &[Duration::ZERO, Duration::ZERO],
        || Ok(TerminalStartup::Pending),
        || {
            Ok(readiness
                .pop_front()
                .expect("one readiness result per probe"))
        },
    )
    .expect("stable exact tmux client identity proves attachment");

    assert_eq!(observed, identity);
}
use std::collections::VecDeque;
use std::sync::{Barrier, atomic::AtomicUsize, mpsc};

#[test]
fn revision_consistent_read_retries_a_projection_crossing_an_update() {
    let revision = AtomicU64::new(1);
    let writers = AtomicUsize::new(0);
    let mut reads = 0;

    let observed = read_revision_consistent(&revision, &writers, |captured| {
        reads += 1;
        if reads == 1 {
            revision.fetch_add(1, Ordering::Release);
        }
        (captured, reads)
    });

    assert_eq!(observed, (2, 2));
}

#[test]
fn revision_consistent_read_waits_for_a_multi_field_publication() {
    let revision = Arc::new(AtomicU64::new(1));
    let writers = Arc::new(AtomicUsize::new(1));
    let value = Arc::new(AtomicUsize::new(1));
    let reader_revision = Arc::clone(&revision);
    let reader_writers = Arc::clone(&writers);
    let reader_value = Arc::clone(&value);
    // The closure records whether any invocation ever ran while a writer
    // was active — a sticky flag rather than a timed negative window, so a
    // regression that reads early fails no matter how threads schedule.
    let entered_with_writer = Arc::new(AtomicBool::new(false));
    let reader_entered_with_writer = Arc::clone(&entered_with_writer);
    let reader = thread::spawn(move || {
        read_revision_consistent(&reader_revision, &reader_writers, |captured| {
            if reader_writers.load(Ordering::Acquire) > 0 {
                reader_entered_with_writer.store(true, Ordering::Release);
            }
            (captured, reader_value.load(Ordering::Acquire))
        })
    });

    value.store(2, Ordering::Release);
    revision.fetch_add(1, Ordering::Release);
    writers.fetch_sub(1, Ordering::Release);

    assert_eq!(reader.join().expect("snapshot reader"), (2, 2));
    assert!(
        !entered_with_writer.load(Ordering::Acquire),
        "the consistent read never ran while a writer was active"
    );
}

#[test]
fn session_operation_fence_spans_launch_until_publication() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let launch = workspace
        .scene
        .runtime
        .session_operations
        .lock()
        .expect("launch operation");
    let (waiting_tx, waiting_rx) = mpsc::channel();
    let (entered_tx, entered_rx) = mpsc::channel();
    let published = Arc::new(AtomicBool::new(false));
    let lifecycle_published = Arc::clone(&published);
    let lifecycle_workspace = workspace.clone();
    let lifecycle = thread::spawn(move || {
        waiting_tx.send(()).expect("announce lifecycle wait");
        let _lifecycle = lifecycle_workspace
            .scene
            .runtime
            .session_operations
            .lock()
            .expect("lifecycle operation");
        entered_tx
            .send(lifecycle_published.load(Ordering::Acquire))
            .expect("announce lifecycle entry");
    });

    waiting_rx.recv().expect("lifecycle reached fence");
    // The entering thread reports whether publication had finished when it
    // acquired the lane; the mutex makes a true report unreachable while
    // the launch guard is held, so an early entry fails deterministically.
    published.store(true, Ordering::Release);
    drop(launch);
    assert!(
        entered_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("lifecycle enters after publication"),
        "lifecycle mutation waited for the in-flight client publication"
    );
    lifecycle.join().expect("lifecycle thread");
}

#[test]
fn lifecycle_registration_waits_for_the_herdr_launch_fence() {
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
    let key = HerdrOperationKey {
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        name: "review".to_owned(),
    };
    let lifecycle = Mutex::new(HerdrLifecycleState::default());

    with_herdr_launch_fence(
        &lifecycle,
        &key,
        || (),
        || {
            assert!(
                lifecycle.try_lock().is_err(),
                "client launch must hold the lifecycle registration lock"
            );
            Ok(())
        },
    )
    .expect("launch without an operation");

    lifecycle
        .lock()
        .expect("lifecycle state")
        .in_flight
        .push(InFlightHerdrLifecycle {
            operation_id: 1,
            key: key.clone(),
            action: HerdrLifecycleAction::Stop,
            reconcile_after_generation: None,
            recovery: None,
        });
    let mut launched = false;
    assert!(
        with_herdr_launch_fence(
            &lifecycle,
            &key,
            || "blocked",
            || {
                launched = true;
                Ok("launched")
            },
        )
        .is_err()
    );
    assert!(!launched, "an in-flight Stop must fence client launch");
}

struct BlockingRestoreRunner {
    entered: Mutex<Option<mpsc::SyncSender<()>>>,
    release: Mutex<mpsc::Receiver<()>>,
}

impl CommandRunner for BlockingRestoreRunner {
    fn run(
        &self,
        _program: &std::ffi::OsStr,
        _args: &[std::ffi::OsString],
        _cancellation: &CancellationToken,
        _timeout: Duration,
    ) -> std::io::Result<host::CommandOutput> {
        if let Some(entered) = self.entered.lock().expect("entered signal").take() {
            entered.send(()).expect("announce blocked discovery");
            self.release
                .lock()
                .expect("release signal")
                .recv()
                .expect("release blocked discovery");
        }
        Err(std::io::Error::new(
            std::io::ErrorKind::ConnectionAborted,
            "fixture discovery stopped",
        ))
    }
}

#[test]
fn delayed_herdr_recoveries_land_on_their_owner_or_nowhere() {
    // Scene B owns a suppressed active selection; the refresh that
    // releases it runs on scene A. In this hostless fixture the restore
    // fails at navigation-target resolution — and that failure event is
    // the discriminator: it must surface in the owning scene's operation
    // events, not the refreshing scene's, and nowhere once the owner has
    // closed.
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let b = a.open_scene();
    let selection = SessionSelection::for_kind("wsl", "Ubuntu", "review", SessionKind::Herdr);
    let suppressed = SuppressedHerdrPresentation {
        restarts: Vec::new(),
        scene_id: b.scene.id,
        active_selection: Some(selection.clone()),
        retained: None,
        navigation_generation: b.scene.navigation_generation.load(Ordering::Acquire),
    };
    Workspace::restore_delayed_herdr_presentations(&a.scene, vec![suppressed]);
    let (a_events, _) = a.drain_events();
    assert!(
        !a_events
            .iter()
            .any(|event| matches!(event, WorkspaceEvent::Error(_))),
        "the refreshing scene never receives the owner's restore outcome"
    );
    let (b_events, _) = b.drain_events();
    assert!(
        b_events.iter().any(|event| matches!(
            event,
            WorkspaceEvent::Error(message) if message.contains("could not restore")
        )),
        "the owner's scene carries its recovery's restore outcome"
    );

    let owned_by_b = SuppressedHerdrPresentation {
        restarts: Vec::new(),
        scene_id: b.scene.id,
        active_selection: Some(selection),
        retained: None,
        navigation_generation: b.scene.navigation_generation.load(Ordering::Acquire),
    };
    b.close();
    Workspace::restore_delayed_herdr_presentations(&a.scene, vec![owned_by_b]);
    let (a_events, _) = a.drain_events();
    assert!(
        !a_events
            .iter()
            .any(|event| matches!(event, WorkspaceEvent::Error(_))),
        "a closed owner's recovery is dropped, not reassigned to the refresher"
    );
}

#[test]
fn retained_herdr_recovery_does_not_block_snapshots_during_discovery() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let snapshot = HostSnapshot::test_fixture_with_herdr(
        "Ubuntu",
        "boot",
        42,
        Vec::new(),
        HerdrInventory::Unavailable,
    );
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let runner: SharedCommandRunner = Arc::new(BlockingRestoreRunner {
        entered: Mutex::new(Some(entered_tx)),
        release: Mutex::new(release_rx),
    });
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let request = AttachRequest {
        host_id: "wsl".to_owned(),
        host,
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Herdr {
            executable: "/opt/herdr/bin/herdr".to_owned(),
            is_default: false,
            session_directory: "/tmp/herdr/review".to_owned(),
            socket_path: "/tmp/herdr/review/herdr.sock".to_owned(),
        },
        name: "review".to_owned(),
        inventory_generation: 1,
    };
    let suppressed = SuppressedHerdrPresentation {
        restarts: Vec::new(),
        scene_id: workspace.scene.id,
        active_selection: None,
        retained: Some(ClosedRetainedPresentation {
            key: request.presentation_key(),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm256Color,
                generation: 1,
                fallback: None,
            },
            presentation_id: 1,
        }),
        navigation_generation: 0,
    };
    let recovery_workspace = workspace.clone();
    let recovery = thread::spawn(move || {
        recovery_workspace.restore_suppressed_herdr_presentation(Some(suppressed));
    });
    entered_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("recovery reached WSL discovery");

    let snapshot_workspace = workspace.clone();
    let (snapshot_tx, snapshot_rx) = mpsc::sync_channel(1);
    let snapshot_reader = thread::spawn(move || {
        let _snapshot = snapshot_workspace.snapshot();
        snapshot_tx.send(()).expect("publish completed read");
    });
    let snapshot_completed = snapshot_rx.recv_timeout(Duration::from_millis(250)).is_ok();

    release_tx.send(()).expect("release WSL discovery");
    recovery.join().expect("recovery task");
    snapshot_reader.join().expect("snapshot reader");
    assert!(
        snapshot_completed,
        "slow retained recovery must not hold the snapshot publication guard"
    );
}

type SpawnFailureHook = Box<dyn FnOnce() + Send>;

#[derive(Default)]
struct ManualRefreshRuntime {
    work: Mutex<VecDeque<RefreshTask>>,
    deadlines: Mutex<VecDeque<(Duration, CancellationToken, RefreshTask)>>,
    fail_next_work: AtomicBool,
    before_spawn_failure: Mutex<Option<SpawnFailureHook>>,
    /// The recorded pump tick; the manual runtime never runs it, keeping
    /// tests on the synchronous `pump_once` entry point.
    pump: Mutex<Option<PumpTask>>,
}

impl ManualRefreshRuntime {
    fn run_next_work(&self) {
        let task = self.work.lock().expect("work queue").pop_front();
        task.expect("queued work")();
    }

    fn run_next_deadline(&self) {
        let task = self
            .deadlines
            .lock()
            .expect("deadline queue")
            .pop_front()
            .map(|(_, cancellation, task)| (cancellation, task));
        let (cancellation, task) = task.expect("queued deadline");
        if !cancellation.is_cancelled() {
            task();
        }
    }

    fn deadline_delays(&self) -> Vec<Duration> {
        self.deadlines
            .lock()
            .expect("deadline queue")
            .iter()
            .map(|(delay, _, _)| *delay)
            .collect()
    }

    fn fail_next_work(&self, before_failure: impl FnOnce() + Send + 'static) {
        *self
            .before_spawn_failure
            .lock()
            .expect("spawn failure hook") = Some(Box::new(before_failure));
        self.fail_next_work.store(true, Ordering::Release);
    }
}

impl RefreshRuntime for ManualRefreshRuntime {
    fn spawn(&self, _name: &str, task: RefreshTask) -> std::io::Result<()> {
        if self.fail_next_work.swap(false, Ordering::AcqRel) {
            if let Some(before_failure) = self
                .before_spawn_failure
                .lock()
                .expect("spawn failure hook")
                .take()
            {
                before_failure();
            }
            return Err(std::io::Error::other("scripted work spawn failure"));
        }
        self.work.lock().expect("work queue").push_back(task);
        Ok(())
    }

    fn spawn_after(
        &self,
        _name: &str,
        delay: Duration,
        cancellation: CancellationToken,
        task: RefreshTask,
    ) -> std::io::Result<()> {
        self.deadlines
            .lock()
            .expect("deadline queue")
            .push_back((delay, cancellation, task));
        Ok(())
    }

    fn start_pump(&self, _name: &str, _interval: Duration, tick: PumpTask) -> std::io::Result<()> {
        *self.pump.lock().expect("pump slot") = Some(tick);
        Ok(())
    }
}

fn kwt_worktree_workspace_fixture() -> (Workspace, Arc<ManualRefreshRuntime>) {
    let runtime = Arc::new(ManualRefreshRuntime::default());
    let bundle =
        host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid KWT bundle");
    let config = WslConfig::with_distro("Ubuntu")
        .expect("valid config")
        .with_kwt_bundle(bundle);
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
        Arc::new(SystemWslDiscovery::new()),
        runtime.clone(),
    );
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
    *workspace.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: WslHost::new(
                config,
                Arc::new(StdCommandRunner) as SharedCommandRunner,
                executable,
            ),
            snapshot: snapshot.clone(),
        },
        1,
    ));
    set_inventory_state(&workspace.scene.runtime, &ready_content(&snapshot));
    workspace
        .scene
        .runtime
        .kwt_refresh_generation
        .store(7, Ordering::Release);
    let inventory = KwtInventory::parse(
            br#"[{"repository":"project-id","name":"project","path":"/repos/project","last_touched":null,"registration_fingerprint":"project-fingerprint"}]"#,
            br#"[{"path":"/repos/project","branch":"main","commit_hash":"abc","is_main":true,"created_at":null,"generation":"0123456789abcdef0123456789abcdef","repository":"project-id","session_name":"project-main","tmux_socket_name":null}]"#,
            b"[]",
        )
        .expect("valid KWT inventory");
    publish_kwt_inventory(
        &workspace.scene,
        7,
        snapshot.endpoint(),
        snapshot.runtime(),
        &inventory,
    );
    (workspace, runtime)
}

#[test]
fn cancelling_a_kwt_listing_releases_the_lane_for_its_replacement() {
    let (workspace, runtime) = kwt_worktree_workspace_fixture();
    let first = workspace
        .load_kwt_pull_requests(
            "wsl",
            "Ubuntu",
            "project-id",
            "/repos/project",
            "project-fingerprint",
        )
        .expect("start pull-request listing");

    assert!(workspace.cancel_kwt_worktree_listing(first));
    let second = workspace
        .import_kwt_pull_request(
            "wsl",
            "Ubuntu",
            "project-id",
            "/repos/project",
            "project-fingerprint",
            "17",
        )
        .expect("replacement import starts immediately");

    assert_ne!(
        first, second,
        "listing and navigation operations share one unique ID sequence"
    );
    assert_eq!(runtime.work.lock().expect("work queue").len(), 2);
    runtime.run_next_work();
    assert!(
        workspace.drain_events().0.is_empty(),
        "a cancelled listing cannot publish into a newer operation"
    );
    assert!(
        workspace
            .scene
            .runtime
            .kwt_mutation_in_flight
            .load(Ordering::Acquire),
        "the cancelled task cannot settle over its replacement"
    );
}

#[test]
fn pull_request_import_timeout_requests_reconciliation_and_reports_uncertainty() {
    let (outcome, message) = kwt_pull_request_import_failure(
        DiagnosticKind::Timeout,
        "import KWT pull request: inventory_timeout",
    );

    assert!(outcome.refresh_kwt);
    assert!(!outcome.refresh_tmux);
    assert!(message.contains("may have completed"));
    assert!(message.contains("refresh"));
}

struct BlockingDiscovery {
    snapshot: HostSnapshot,
    entered: Mutex<Option<mpsc::SyncSender<()>>>,
    release: Mutex<mpsc::Receiver<()>>,
}

impl WslDiscovery for BlockingDiscovery {
    fn discover(
        &self,
        config: WslConfig,
        executable: WslExecutable,
        existing_host: Option<RuntimeHost>,
        _cancellation: &CancellationToken,
    ) -> Result<HostContext, HostError> {
        if let Some(entered) = self.entered.lock().expect("entered signal").take() {
            entered.send(()).expect("announce blocked discovery");
        }
        self.release
            .lock()
            .expect("release signal")
            .recv()
            .expect("release blocked discovery");
        let host = existing_host
            .unwrap_or_else(|| WslHost::new(config, Arc::new(StdCommandRunner), executable));
        Ok(HostContext {
            host,
            snapshot: self.snapshot.clone(),
        })
    }
}

struct FixedDiscovery {
    snapshot: HostSnapshot,
    reused_hosts: AtomicUsize,
}

impl FixedDiscovery {
    fn new(snapshot: HostSnapshot) -> Self {
        Self {
            snapshot,
            reused_hosts: AtomicUsize::new(0),
        }
    }
}

impl WslDiscovery for FixedDiscovery {
    fn discover(
        &self,
        config: WslConfig,
        executable: WslExecutable,
        existing_host: Option<RuntimeHost>,
        _cancellation: &CancellationToken,
    ) -> Result<HostContext, HostError> {
        let runner: SharedCommandRunner = Arc::new(StdCommandRunner);
        let host = existing_host.map_or_else(
            || WslHost::new(config, runner, executable),
            |host| {
                self.reused_hosts.fetch_add(1, Ordering::AcqRel);
                host
            },
        );
        Ok(HostContext {
            host,
            snapshot: self.snapshot.clone(),
        })
    }
}

fn presentation_key_fixture(
    kernel_boot_id: &str,
    init_start_ticks: u64,
    identity: session::SessionIdentity,
) -> PresentationKey {
    let snapshot =
        HostSnapshot::test_fixture("Ubuntu", kernel_boot_id, init_start_ticks, Vec::new());
    PresentationKey {
        host_id: "wsl".to_owned(),
        endpoint: "Ubuntu".to_owned(),
        socket_directory: None,
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Tmux(identity),
    }
}

fn fallback_fixture(
    kernel_boot_id: &str,
    init_start_ticks: u64,
    identity: session::SessionIdentity,
    navigation_generation: u64,
) -> FallbackAuthority {
    let presentation = presentation_key_fixture(kernel_boot_id, init_start_ticks, identity);
    FallbackAuthority {
        target: presentation.clone(),
        presentation,
        navigation_generation,
    }
}

fn captured_request(workspace: &Workspace, name: &str) -> AttachRequest {
    capture_attach_request(
        &workspace.scene,
        &SessionSelection::new("wsl", "Ubuntu", name),
    )
    .expect("fixture session is present")
}

#[cfg(windows)]
fn attach_request_fixture(
    snapshot: &HostSnapshot,
    identity: session::SessionIdentity,
    name: &str,
) -> AttachRequest {
    attach_request_fixture_with_runner(
        snapshot,
        identity,
        name,
        Arc::new(StdCommandRunner) as SharedCommandRunner,
    )
}

fn attach_request_fixture_with_runner(
    snapshot: &HostSnapshot,
    identity: session::SessionIdentity,
    name: &str,
    runner: SharedCommandRunner,
) -> AttachRequest {
    AttachRequest {
        host_id: "wsl".to_owned(),
        host: WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            runner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        ),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Tmux(identity),
        name: name.to_owned(),
        inventory_generation: 1,
    }
}

#[cfg(windows)]
fn herdr_attach_request_fixture(snapshot: &HostSnapshot, name: &str) -> AttachRequest {
    AttachRequest {
        host_id: "wsl".to_owned(),
        host: WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            Arc::new(StdCommandRunner) as SharedCommandRunner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        ),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Herdr {
            executable: "/opt/herdr/bin/herdr".to_owned(),
            is_default: false,
            session_directory: "/tmp/herdr/review".to_owned(),
            socket_path: "/tmp/herdr/review/herdr.sock".to_owned(),
        },
        name: name.to_owned(),
        inventory_generation: 1,
    }
}

#[cfg(windows)]
fn zellij_attach_request_fixture(snapshot: &HostSnapshot, name: &str) -> AttachRequest {
    AttachRequest {
        host_id: "wsl".to_owned(),
        host: WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            Arc::new(StdCommandRunner) as SharedCommandRunner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        ),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Zellij {
            executable: "/usr/bin/zellij".to_owned(),
            name: name.to_owned(),
        },
        name: name.to_owned(),
        inventory_generation: 1,
    }
}

#[test]
fn terminal_event_drain_reserves_progress_for_retained_workers() {
    assert_eq!(ACTIVE_EVENT_BUDGET, MAX_EVENTS_PER_DRAIN - 8);
    assert_eq!(
        retained_event_budget(ACTIVE_EVENT_BUDGET, false),
        RETAINED_EVENT_RESERVE
    );
    assert!(!event_source_may_have_more(
        ACTIVE_EVENT_BUDGET - 1,
        ACTIVE_EVENT_BUDGET,
        false
    ));
    assert!(event_source_may_have_more(
        ACTIVE_EVENT_BUDGET,
        ACTIVE_EVENT_BUDGET,
        false
    ));
    assert!(!event_source_may_have_more(
        ACTIVE_EVENT_BUDGET,
        ACTIVE_EVENT_BUDGET,
        true
    ));
}

#[test]
fn appearance_projects_terminal_default_colors() {
    let appearance = Appearance {
        theme: TerminalTheme::Custom,
        font_family: "monospace".to_owned(),
        font_size: 14,
        background: 0x12_34_56,
        foreground: 0x65_43_21,
        cursor_style: CursorStyle::Block,
        allow_shell_integration_cursor: false,
        hide_mouse_while_typing: true,
    };

    let colors = default_colors(&appearance);

    assert_eq!(colors.background(), Rgb::new(0x12, 0x34, 0x56));
    assert_eq!(colors.foreground(), Rgb::new(0x65, 0x43, 0x21));
}

#[test]
fn atomic_attach_identity_mismatch_has_a_specific_diagnostic() {
    let (retry_term, diagnostic) = classify_terminal_exit_event(
        0,
        session::IDENTITY_MISMATCH_MARKER,
        AttachTerm::Xterm256Color,
        false,
    );

    assert!(!retry_term);
    assert_eq!(
        diagnostic.as_deref(),
        Some("session identity changed immediately before attachment; refresh and try again")
    );
}

#[test]
fn application_attachment_failure_stays_on_the_wsl_host() {
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application(TerminalAppearance::default(), Some(spec));
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "work".to_owned(),
            kind: SessionKind::Tmux,
        },
    );

    publish_attachment_failure(
        &workspace.scene,
        0,
        WorkspaceError::new("attachment launch failed"),
    );

    let snapshot = workspace.snapshot();
    assert!(matches!(snapshot.content(), WorkspaceContent::Shell));
    let host = &snapshot.hosts()[0];
    assert_eq!(host.connection(), HostConnectionState::Unavailable);
    assert_eq!(
        host.diagnostic().map(HostDiagnostic::message),
        Some("attachment launch failed")
    );
}

#[test]
fn stale_attachment_failure_cannot_overwrite_a_newer_host_refresh() {
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application(TerminalAppearance::default(), Some(spec));
    let newer_generation = begin_refresh(
        &workspace.scene,
        &CancellationToken::new(),
        RefreshPresentation::Connecting,
    );
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "stale".to_owned(),
            kind: SessionKind::Tmux,
        },
    );

    publish_attachment_failure(
        &workspace.scene,
        newer_generation - 1,
        WorkspaceError::new("stale attachment failure"),
    );

    let snapshot = workspace.snapshot();
    assert!(matches!(snapshot.content(), WorkspaceContent::Shell));
    let host = &snapshot.hosts()[0];
    assert_eq!(host.connection(), HostConnectionState::Connecting);
    assert_eq!(host.diagnostic(), None);
}

#[test]
fn stale_attachment_refreshes_inventory_without_disabling_the_host() {
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let workspace = Workspace::application(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
    );
    let host = WslHost::new(
        config,
        Arc::new(StdCommandRunner) as SharedCommandRunner,
        executable,
    );
    let original = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "work",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    );
    *workspace
        .scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
        HostContext {
            host,
            snapshot: original,
        },
        0,
    ));
    set_inventory_state(
        &workspace.scene.runtime,
        &WorkspaceContent::Ready {
            endpoint: "Ubuntu".to_owned(),
            sessions: vec![SessionItem::new("work", 0)],
        },
    );
    let request = capture_attach_request(
        &workspace.scene,
        &SessionSelection::new("wsl", "Ubuntu", "work"),
    )
    .expect("attach request");
    let replacement = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "other",
            session::SessionIdentity::new(100, "$2", 201),
            0,
        )],
    );

    publish_stale_attachment_failure(
        &workspace.scene,
        &request,
        replacement,
        &WorkspaceError::new("session no longer exists"),
    );

    let snapshot = workspace.snapshot();
    assert!(matches!(snapshot.content(), WorkspaceContent::Shell));
    let host = &snapshot.hosts()[0];
    assert_eq!(host.connection(), HostConnectionState::Ready);
    assert_eq!(host.sessions(), &[SessionItem::new("other", 0)]);
    assert_eq!(snapshot.notice(), Some("session no longer exists"));
}

#[test]
fn retained_stale_failure_preserves_the_visible_terminal_and_pending_input() {
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let workspace = Workspace::application(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
    );
    let host = WslHost::new(
        config,
        Arc::new(StdCommandRunner) as SharedCommandRunner,
        executable,
    );
    let original = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "hidden",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    );
    *workspace
        .scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
        HostContext {
            host,
            snapshot: original,
        },
        0,
    ));
    let request = capture_attach_request(
        &workspace.scene,
        &SessionSelection::new("wsl", "Ubuntu", "hidden"),
    )
    .expect("hidden attach request");
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "visible".to_owned(),
            kind: SessionKind::Tmux,
            presentation_id: 9,
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(
                1,
                GridSize::new(80, 24).expect("valid grid"),
            ))),
        },
    );
    *workspace.scene.pending_paste.lock().expect("pending paste") = Some(PendingPaste {
        worker_generation: 7,
        input: input::encode_input(
            &KeyInput::paste("pending\ninput"),
            input::TerminalModes::default(),
        ),
    });
    let replacement = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());

    publish_retained_stale_failure(
        &workspace.scene,
        &request,
        replacement,
        &WorkspaceError::new("hidden session changed"),
    );

    let snapshot = workspace.snapshot();
    assert!(matches!(
        snapshot.content(),
        WorkspaceContent::Terminal { session, presentation_id, .. }
            if session == "visible" && *presentation_id == 9
    ));
    assert!(
        workspace
            .scene
            .pending_paste
            .lock()
            .expect("pending paste")
            .is_some()
    );
    assert_eq!(snapshot.notice(), Some("hidden session changed"));
    assert!(snapshot.hosts()[0].sessions().is_empty());
}

#[test]
fn legacy_attachment_failure_remains_top_level() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));

    publish_attachment_failure(
        &workspace.scene,
        0,
        WorkspaceError::new("legacy attachment failed"),
    );

    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Error { message } if message == "legacy attachment failed"
    ));
}

#[test]
fn terminal_output_that_only_contains_the_marker_is_not_an_attach_mismatch() {
    let output = format!("shell output: {}\r\n", session::IDENTITY_MISMATCH_MARKER);

    let (retry_term, diagnostic) =
        classify_terminal_exit_event(0, &output, AttachTerm::Xterm256Color, false);

    assert!(!retry_term);
    assert_eq!(diagnostic, None);
}

#[test]
fn remote_identity_mismatch_tolerates_preceding_login_shell_noise() {
    let marker = "GHOSTHUB_REMOTE_IDENTITY_MISMATCH_deadbeef";
    let output =
        format!("Welcome to the remote host\r\n{marker}\r\nlogout\r\nConnection closed.\r\n");

    let diagnostic = classify_remote_terminal_exit(0, &output, Some(marker))
        .expect("the attachment-specific marker is authoritative");

    assert!(diagnostic.contains("session identity changed"));
}

#[test]
fn remote_output_that_only_mentions_the_marker_is_not_authoritative() {
    let marker = "GHOSTHUB_REMOTE_IDENTITY_MISMATCH_deadbeef";
    let output = format!("shell output: {marker}\r\nordinary logout\r\n");

    assert_eq!(
        classify_remote_terminal_exit(0, &output, Some(marker)),
        None
    );
}

#[test]
fn initial_exact_terminfo_failure_retries_with_xterm() {
    let (retry_term, diagnostic) = classify_terminal_exit_event(
        1,
        "missing or unsuitable terminal: xterm-256color\r\n",
        AttachTerm::Xterm256Color,
        false,
    );

    assert!(retry_term);
    assert_eq!(diagnostic, None);
}

#[cfg(windows)]
#[test]
fn hidden_unconfirmed_client_keeps_its_identity_and_fallback_during_terminfo_retry() {
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(StdCommandRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let request = AttachRequest {
        host_id: "wsl".to_owned(),
        host,
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Tmux(identity.clone()),
        name: "replacement".to_owned(),
        inventory_generation: 1,
    };
    let key = request.presentation_key();
    let fallback = FallbackAuthority {
        presentation: PresentationKey {
            target: AttachTarget::Tmux(session::SessionIdentity::new(100, "$2", 201)),
            ..key.clone()
        },
        target: key.clone(),
        navigation_generation: 7,
    };
    let mut retained = RetainedPresentations::new();
    retained.insert(RetainedPresentation {
        key: key.clone(),
        selection: SessionSelection::new("wsl", "Ubuntu", "replacement"),
        attachment: ActiveAttachment {
            request,
            term: AttachTerm::Xterm256Color,
            generation: 1,
            fallback: Some(fallback.clone()),
        },
        worker: (),
        presentation_id: 7,
    });
    let mut emitted = Vec::new();
    let mut retries = Vec::new();

    retained.handle_exit(
        0,
        1,
        "missing or unsuitable terminal: xterm-256color\r\n",
        false,
        &mut emitted,
        &mut retries,
    );

    let retry = retries.pop().expect("retained xterm retry");

    assert!(emitted.is_empty());
    assert_eq!(retry.key, key);
    assert!(retained.contains(&key));
    assert_eq!(retained.selections()[0].session(), "replacement");
    assert_eq!(retained.restarting[0].attachment.term, AttachTerm::Xterm);
    assert_eq!(
        retained.restarting[0].attachment.fallback.as_ref(),
        Some(&fallback)
    );

    let mut restored_attachment = AttachmentState::new();
    let rebound_fallback = FallbackAuthority {
        presentation: fallback.presentation.clone(),
        target: fallback.target.clone(),
        navigation_generation: 8,
    };
    let restored_generation = reserve_retained_attachment(
        &mut restored_attachment,
        &retained.restarting[0].attachment,
        Some(rebound_fallback.clone()),
    )
    .expect("reactivate retained attachment");
    let mut restored_worker = WorkerState::new();
    let worker_generation = restored_worker.publish(());
    let fallback_after_reactivation = restored_attachment.fallback_if_current(restored_generation);

    assert!(claim_terminal_exit(
        &mut restored_attachment,
        &mut restored_worker,
        restored_generation,
        worker_generation,
        false,
    ));
    assert_eq!(fallback_after_reactivation, Some(rebound_fallback));
}

#[cfg(windows)]
#[test]
fn retained_terminfo_retry_resolves_a_renamed_session_by_identity() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let original_snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let request = attach_request_fixture(&original_snapshot, identity.clone(), "original");
    let key = request.presentation_key();
    let retry = RetainedRetry {
        key: key.clone(),
        request: request.clone(),
    };
    let renamed_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new("renamed", identity, 0)],
    );
    let resolved_request = resolve_retained_retry_request(&retry, &renamed_snapshot)
        .expect("stable retained identity survives a rename");
    let mut retained = RetainedPresentations::new();
    retained.restarting.push(RetainedRestart {
        key: key.clone(),
        selection: SessionSelection::new("wsl", "Ubuntu", "original"),
        attachment: ActiveAttachment {
            request,
            term: AttachTerm::Xterm,
            generation: 1,
            fallback: None,
        },
        presentation_id: 7,
    });

    assert_eq!(resolved_request.name, "renamed");
    assert!(retained.finish_restart(&key, (), &retry.request.name, &resolved_request));
    assert_eq!(retained.entries[0].selection.session(), "renamed");
    assert_eq!(retained.entries[0].attachment.request.name, "renamed");
}

#[cfg(windows)]
#[test]
fn retained_terminfo_retry_preserves_herdr_selection_kind() {
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let request = herdr_attach_request_fixture(&snapshot, "original");
    let key = request.presentation_key();
    let mut resolved_request = request.clone();
    resolved_request.name = "renamed".to_owned();
    let mut retained = RetainedPresentations::new();
    retained.restarting.push(RetainedRestart {
        key: key.clone(),
        selection: SessionSelection::herdr("wsl", "Ubuntu", "original"),
        attachment: ActiveAttachment {
            request,
            term: AttachTerm::Xterm,
            generation: 1,
            fallback: None,
        },
        presentation_id: 7,
    });

    assert!(retained.finish_restart(&key, (), "original", &resolved_request));
    assert_eq!(retained.entries[0].selection.kind(), SessionKind::Herdr);
    assert_eq!(retained.entries[0].selection.session(), "renamed");
    assert_eq!(
        retained.entries[0].attachment.request.selection().kind(),
        SessionKind::Herdr
    );
}

#[test]
fn presentation_identity_survives_rename_but_not_a_wsl_runtime_restart() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let original = presentation_key_fixture("boot-a", 42, identity.clone());
    let renamed = presentation_key_fixture("boot-a", 42, identity.clone());
    let restarted = presentation_key_fixture("boot-b", 7, identity);

    assert_eq!(original, renamed);
    assert_ne!(original, restarted);
}

#[cfg(windows)]
#[test]
fn current_inventory_identity_wins_over_a_same_name_retained_session() {
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let stale = attach_request_fixture(
        &snapshot,
        session::SessionIdentity::new(100, "$1", 200),
        "demo",
    );
    let current = attach_request_fixture(
        &snapshot,
        session::SessionIdentity::new(100, "$2", 201),
        "demo",
    );

    let (selected, request) =
        choose_navigation_target(Some(stale.presentation_key()), Ok(current.clone()))
            .expect("current session remains selectable");

    assert_eq!(selected, current.presentation_key());
    assert_eq!(request.map(|request| request.target), Some(current.target));
}

#[cfg(windows)]
#[test]
fn inventory_rename_updates_the_retained_display_name_without_changing_its_key() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let original_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "original",
            identity.clone(),
            0,
        )],
    );
    let request = attach_request_fixture(&original_snapshot, identity.clone(), "original");
    let key = request.presentation_key();
    let mut retained = RetainedPresentations::new();
    retained.insert(RetainedPresentation {
        key: key.clone(),
        selection: SessionSelection::new("wsl", "Ubuntu", "original"),
        attachment: ActiveAttachment {
            request: request.clone(),
            term: AttachTerm::Xterm256Color,
            generation: 1,
            fallback: None,
        },
        worker: (),
        presentation_id: 7,
    });
    let stale_activation_key = retained
        .key_for_selection(&SessionSelection::new("wsl", "Ubuntu", "original"))
        .expect("stale caller captured retained identity");
    let renamed_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new("renamed", identity, 0)],
    );

    assert!(retained.reconcile_session_names(&renamed_snapshot, None));

    assert!(retained.contains(&key));
    assert_eq!(retained.selections()[0].session(), "renamed");
    assert_eq!(retained.entries[0].attachment.request.name, "renamed");
    assert_eq!(
        retained.key_for_selection(&SessionSelection::new("wsl", "Ubuntu", "renamed")),
        Some(key.clone())
    );
    let activated = retained
        .take(&stale_activation_key)
        .expect("identity remains activatable after rename");
    assert_eq!(activated.selection.session(), "renamed");
    assert_eq!(activated.attachment.request.name, "renamed");

    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    *workspace.scene.runtime.host.lock().expect("host") = Some(Published::new(
        HostContext {
            host: request.host.clone(),
            snapshot: renamed_snapshot.clone(),
        },
        2,
    ));
    assert_eq!(
        current_inventory_session_name(&workspace.scene.runtime, &key).as_deref(),
        Some("renamed")
    );
    workspace
        .scene
        .attachment
        .lock()
        .expect("attachment")
        .reserve(request, AttachTerm::Xterm256Color)
        .expect("reserve visible attachment");
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "original".to_owned(),
            kind: SessionKind::Tmux,
        },
    );

    reconcile_presentation_session_names(&workspace.scene.runtime, 0, &renamed_snapshot, None);

    assert_eq!(
        workspace
            .scene
            .attachment
            .lock()
            .expect("attachment")
            .active()
            .expect("visible attachment")
            .request
            .name,
        "renamed"
    );
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Attaching { session, .. } if session == "renamed"
    ));
}

#[cfg(windows)]
#[test]
fn inventory_rename_preserves_a_retained_herdr_selection() {
    let original_snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let request = herdr_attach_request_fixture(&original_snapshot, "original");
    let key = request.presentation_key();
    let mut retained = RetainedPresentations::new();
    retained.insert(RetainedPresentation {
        key: key.clone(),
        selection: request.selection(),
        attachment: ActiveAttachment {
            request,
            term: AttachTerm::Xterm256Color,
            generation: 1,
            fallback: None,
        },
        worker: (),
        presentation_id: 7,
    });
    let renamed_snapshot = HostSnapshot::test_fixture_with_herdr(
        "Ubuntu",
        "boot-id",
        42,
        Vec::new(),
        HerdrInventory::Available {
            executable: "/opt/herdr/bin/herdr".to_owned(),
            sessions: vec![session::HerdrSessionRecord::new(
                "renamed",
                false,
                HerdrSessionState::Running,
                "/tmp/herdr/review",
                "/tmp/herdr/review/herdr.sock",
            )],
        },
    );

    assert!(retained.reconcile_session_names(&renamed_snapshot, None));

    assert!(retained.contains(&key));
    assert_eq!(retained.entries[0].selection.kind(), SessionKind::Herdr);
    assert_eq!(retained.entries[0].selection.session(), "renamed");
    assert_eq!(
        retained.key_for_selection(&SessionSelection::herdr("wsl", "Ubuntu", "renamed")),
        Some(key)
    );
}

#[cfg(windows)]
#[test]
fn retained_rename_advances_the_workspace_revision_once() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let original_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "original",
            identity.clone(),
            0,
        )],
    );
    let request = attach_request_fixture(&original_snapshot, identity.clone(), "original");
    let renamed_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new("renamed", identity, 0)],
    );
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    workspace
        .scene
        .retained_presentations
        .lock()
        .expect("retained presentations")
        .restarting
        .push(RetainedRestart {
            key: request.presentation_key(),
            selection: SessionSelection::new("wsl", "Ubuntu", "original"),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm256Color,
                generation: 1,
                fallback: None,
            },
            presentation_id: 7,
        });
    let revision = workspace.snapshot().revision();

    reconcile_retained_session_names(&workspace.scene.runtime, &renamed_snapshot, None);
    let renamed = workspace.snapshot();

    assert_eq!(renamed.revision(), revision + 1);
    assert_eq!(renamed.retained_selections()[0].session(), "renamed");

    reconcile_retained_session_names(&workspace.scene.runtime, &renamed_snapshot, None);
    assert_eq!(workspace.snapshot().revision(), renamed.revision());
}

#[cfg(windows)]
#[test]
fn detach_invalidates_fallback_authority_before_an_async_failure() {
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(StdCommandRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let request = AttachRequest {
        host_id: "wsl".to_owned(),
        host,
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Tmux(session::SessionIdentity::new(100, "$1", 200)),
        name: "replacement".to_owned(),
        inventory_generation: 1,
    };
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let navigation_generation = workspace.begin_navigation();
    let fallback = FallbackAuthority {
        presentation: presentation_key_fixture(
            "boot-id",
            42,
            session::SessionIdentity::new(100, "$2", 201),
        ),
        target: request.presentation_key(),
        navigation_generation,
    };
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "replacement".to_owned(),
            kind: SessionKind::Tmux,
        },
    );

    assert!(fallback_owns_request(&workspace.scene, &fallback, &request));
    workspace.detach();
    assert!(!fallback_owns_request(
        &workspace.scene,
        &fallback,
        &request
    ));
}

#[cfg(windows)]
#[test]
fn failed_attachment_context_uses_stable_identity_after_name_reconciliation() {
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let request = attach_request_fixture(
        &snapshot,
        session::SessionIdentity::new(100, "$1", 200),
        "original",
    );
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let navigation_generation = workspace.begin_navigation();
    let mut fallback = fallback_fixture(
        "boot-id",
        42,
        session::SessionIdentity::new(100, "$2", 201),
        navigation_generation,
    );
    fallback.target = request.presentation_key();
    let generation = workspace
        .scene
        .attachment
        .lock()
        .expect("attachment")
        .reserve_with_fallback(request, AttachTerm::Xterm256Color, Some(fallback.clone()))
        .expect("reserve attachment");
    {
        let mut attachment = workspace.scene.attachment.lock().expect("attachment");
        attachment
            .active_mut()
            .expect("active attachment")
            .request
            .name = "renamed".to_owned();
    }
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "original".to_owned(),
            kind: SessionKind::Tmux,
        },
    );

    let attachment = workspace.scene.attachment.lock().expect("attachment");
    let (failed_request, restored_fallback) =
        failed_attachment_context(&workspace.scene, &attachment, generation)
            .expect("current failure context");

    assert_eq!(failed_request.name, "renamed");
    assert_eq!(restored_fallback, Some(fallback));
}

#[test]
fn terminfo_retry_unpublishes_terminal_and_preserves_session_kind() {
    let size = GridSize::new(80, 24).expect("valid grid");
    let workspace = Workspace::preview(WorkspaceSnapshot {
        revision: 1,
        appearance: Appearance::default(),
        content: WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "work".to_owned(),
            kind: SessionKind::Tmux,
            presentation_id: 7,
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
        },
        hosts: Vec::new(),
        selected_host: None,
        notice: None,
        active_selection: None,
        retained_selections: Vec::new(),
    });
    *workspace.scene.pending_paste.lock().expect("pending paste") = Some(PendingPaste {
        worker_generation: 1,
        input: input::encode_input(
            &KeyInput::paste("first\nsecond"),
            input::TerminalModes::default(),
        ),
    });

    publish_terminfo_retry_boundary(
        &workspace.scene,
        "wsl",
        "Ubuntu",
        "work",
        SessionKind::Herdr,
    );

    assert!(
        workspace
            .scene
            .pending_paste
            .lock()
            .expect("pending paste")
            .is_none()
    );
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Attaching { host_id, endpoint, session, kind, .. }
            if host_id == "wsl"
                && endpoint == "Ubuntu"
                && session == "work"
                && *kind == SessionKind::Herdr
    ));
    assert_eq!(next_presentation_id(&workspace.scene.runtime), 8);
}

#[test]
fn successful_xterm_fallback_notice_persists_until_detach() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));

    set_terminal_notice(&workspace.scene, AttachTerm::Xterm);

    assert_eq!(workspace.snapshot().notice(), Some(REDUCED_COLOR_NOTICE));
    workspace.detach();
    assert_eq!(workspace.snapshot().notice(), None);
}

#[test]
fn established_client_exit_never_uses_terminfo_fallback() {
    let (retry_term, diagnostic) = classify_terminal_exit_event(
        1,
        "missing or unsuitable terminal: xterm-256color\r\n",
        AttachTerm::Xterm256Color,
        true,
    );

    assert!(!retry_term);
    assert_eq!(
        diagnostic.as_deref(),
        Some("tmux client exited with status 1")
    );
}

#[test]
fn pane_output_containing_terminfo_text_is_not_a_startup_failure() {
    let (retry_term, diagnostic) = classify_terminal_exit_event(
        1,
        "previous pane output\r\nmissing or unsuitable terminal: xterm-256color\r\n",
        AttachTerm::Xterm256Color,
        false,
    );

    assert!(!retry_term);
    assert_eq!(
        diagnostic.as_deref(),
        Some("tmux client exited with status 1")
    );
}

#[test]
fn captured_host_generation_cannot_overwrite_a_later_refresh() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let context_generation = workspace
        .scene
        .runtime
        .refresh_generation
        .load(Ordering::Acquire);
    let runner: SharedCommandRunner = Arc::new(StdCommandRunner);
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        runner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute system WSL path"),
    );
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "work",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    );
    *workspace
        .scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
        HostContext { host, snapshot },
        context_generation,
    ));
    *workspace
        .scene
        .selected_host
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some("wsl".to_owned());
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "work".to_owned(),
            kind: SessionKind::Tmux,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(
                1,
                GridSize::new(80, 24).expect("valid grid"),
            ))),
        },
    );

    let refresh_generation = begin_refresh(
        &workspace.scene,
        &CancellationToken::new(),
        RefreshPresentation::Connecting,
    );
    let request = capture_attach_request(
        &workspace.scene,
        &SessionSelection::new("wsl", "Ubuntu", "work"),
    )
    .expect("capture request");
    assert_eq!(request.inventory_generation, context_generation);
    assert!(refresh_generation > request.inventory_generation);
    assert!(publish_refresh(
        &workspace.scene.runtime,
        refresh_generation,
        || set_inventory_state(
            &workspace.scene.runtime,
            &WorkspaceContent::Ready {
                endpoint: "Ubuntu".to_owned(),
                sessions: vec![SessionItem::new("newer", 0)],
            },
        )
    ));
    assert!(!publish_refresh(
        &workspace.scene.runtime,
        request.inventory_generation,
        || set_inventory_state(
            &workspace.scene.runtime,
            &WorkspaceContent::Ready {
                endpoint: "Ubuntu".to_owned(),
                sessions: vec![SessionItem::new("stale", 0)],
            },
        )
    ));

    workspace.restore_inventory_state();

    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Ready { sessions, .. }
            if sessions.len() == 1 && sessions[0].name() == "newer"
    ));
}

#[test]
fn created_session_is_resolved_by_client_identity_not_requested_name() {
    let client_identity = session::SessionIdentity::new(100, "$1", 200);
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![
            session::DiscoveredSession::new(
                "requested",
                session::SessionIdentity::new(100, "$2", 201),
                0,
            ),
            session::DiscoveredSession::new("renamed-by-hook", client_identity.clone(), 1),
        ],
    );

    let created = created_session(&snapshot, &client_identity).expect("client session");

    assert_eq!(created.name(), "renamed-by-hook");
    assert_eq!(created.identity(), &client_identity);
}

#[test]
fn creation_identity_report_gets_a_bounded_startup_width() {
    let narrow = TerminalGeometry {
        grid: GridSize::new(20, 12).expect("valid narrow grid"),
        pixels: PixelSize::new(200, 240),
        sequence: 7,
    };

    let launch = creation_launch_geometry(narrow);

    assert_eq!(launch.grid.columns(), CREATE_IDENTITY_MIN_COLUMNS);
    assert_eq!(launch.grid.rows(), narrow.grid.rows());
    assert_eq!(launch.pixels, narrow.pixels);
    assert_eq!(launch.sequence, narrow.sequence);
    assert_eq!(
        creation_launch_geometry(launch),
        launch,
        "already-wide grids are unchanged"
    );
}

#[test]
fn post_create_inventory_cannot_overwrite_a_newer_refresh() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let runner: SharedCommandRunner = Arc::new(StdCommandRunner);
    let runtime_host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        runner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute system WSL path"),
    );
    let initial_generation = workspace
        .scene
        .runtime
        .refresh_generation
        .load(Ordering::Acquire);
    let initial_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "before",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    );
    *workspace.scene.runtime.host.lock().expect("host context") = Some(Published::new(
        HostContext {
            host: runtime_host.clone(),
            snapshot: initial_snapshot.clone(),
        },
        initial_generation,
    ));
    let request = CreateRequest {
        host_id: "wsl".to_owned(),
        host: runtime_host.clone(),
        endpoint: initial_snapshot.endpoint().clone(),
        runtime: initial_snapshot.runtime().clone(),
        name: SessionName::parse("created").expect("valid name"),
    };

    let operation_generation = reserve_constructive_inventory(&workspace.scene.runtime);
    let refresh_generation = begin_refresh(
        &workspace.scene,
        &CancellationToken::new(),
        RefreshPresentation::Connecting,
    );
    let refreshed = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "refreshed",
            session::SessionIdentity::new(100, "$2", 201),
            0,
        )],
    );
    assert!(publish_refresh(
        &workspace.scene.runtime,
        refresh_generation,
        || {
            *workspace.scene.runtime.host.lock().expect("host context") = Some(Published::new(
                HostContext {
                    host: runtime_host,
                    snapshot: refreshed,
                },
                refresh_generation,
            ));
        }
    ));
    let created = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "created",
            session::SessionIdentity::new(100, "$3", 202),
            1,
        )],
    );

    let merged = merge_created_inventory(&workspace.scene, &request, created, operation_generation);

    assert!(merged.is_err());
    let host = workspace.scene.runtime.host.lock().expect("host context");
    let published = host.as_ref().expect("published host");
    assert_eq!(published.generation, refresh_generation);
    assert_eq!(published.value.snapshot.sessions()[0].name(), "refreshed");
}

#[test]
fn post_create_inventory_supersedes_an_inflight_refresh() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let runner: SharedCommandRunner = Arc::new(StdCommandRunner);
    let runtime_host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        runner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute system WSL path"),
    );
    let initial_generation = workspace
        .scene
        .runtime
        .refresh_generation
        .load(Ordering::Acquire);
    let initial_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "before",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    );
    *workspace.scene.runtime.host.lock().expect("host context") = Some(Published::new(
        HostContext {
            host: runtime_host.clone(),
            snapshot: initial_snapshot.clone(),
        },
        initial_generation,
    ));
    let request = CreateRequest {
        host_id: "wsl".to_owned(),
        host: runtime_host,
        endpoint: initial_snapshot.endpoint().clone(),
        runtime: initial_snapshot.runtime().clone(),
        name: SessionName::parse("created").expect("valid name"),
    };
    let cancellation = CancellationToken::new();
    let refresh_generation = begin_refresh(
        &workspace.scene,
        &cancellation,
        RefreshPresentation::Connecting,
    );
    let operation_generation = reserve_constructive_inventory(&workspace.scene.runtime);
    let created = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "created",
            session::SessionIdentity::new(100, "$2", 201),
            1,
        )],
    );

    let merged = merge_created_inventory(&workspace.scene, &request, created, operation_generation)
        .expect("merge post-create inventory");

    assert_eq!(merged, operation_generation);
    assert!(merged > refresh_generation);
    assert!(cancellation.is_cancelled());
    assert!(!publish_refresh(
        &workspace.scene.runtime,
        refresh_generation,
        || panic!("superseded refresh must not publish")
    ));
    let host = workspace.scene.runtime.host.lock().expect("host context");
    let published = host.as_ref().expect("published host");
    assert_eq!(published.generation, merged);
    assert_eq!(published.value.snapshot.sessions()[0].name(), "created");
}

#[test]
fn failed_herdr_restart_during_refresh_restores_cached_ready_host() {
    let (workspace, _runtime) = herdr_workspace_fixture();
    let navigation_generation = workspace.begin_navigation();
    let operation_cancellation = CancellationToken::new();
    let refresh_cancellation = CancellationToken::new();
    let refresh_generation = begin_refresh(
        &workspace.scene,
        &refresh_cancellation,
        RefreshPresentation::Connecting,
    );
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Connecting
    );

    let operation_generation = reserve_current_constructive_inventory(
        &workspace.scene,
        navigation_generation,
        &operation_cancellation,
    )
    .expect("current restart reserves inventory publication");
    assert!(operation_generation > refresh_generation);
    assert!(refresh_cancellation.is_cancelled());

    settle_constructive_inventory(&workspace.scene, operation_generation);

    let snapshot = workspace.snapshot();
    let host = &snapshot.hosts()[0];
    assert_eq!(host.connection(), HostConnectionState::Ready);
    assert_eq!(host.sessions()[0].name(), "work");
    assert_eq!(host.herdr_sessions().len(), 2);
}

#[test]
fn stale_or_cancelled_herdr_restart_cannot_cancel_a_newer_refresh() {
    let (workspace, _runtime) = herdr_workspace_fixture();
    let queued_navigation = workspace.begin_navigation();
    let cancelled = CancellationToken::new();
    cancelled.cancel();
    let refresh_cancellation = CancellationToken::new();
    let refresh_generation = begin_refresh(
        &workspace.scene,
        &refresh_cancellation,
        RefreshPresentation::Connecting,
    );

    assert_eq!(
        reserve_current_constructive_inventory(&workspace.scene, queued_navigation, &cancelled,),
        None
    );
    let active = CancellationToken::new();
    workspace.begin_navigation();
    assert_eq!(
        reserve_current_constructive_inventory(&workspace.scene, queued_navigation, &active,),
        None
    );

    assert!(!refresh_cancellation.is_cancelled());
    assert_eq!(
        workspace
            .scene
            .runtime
            .refresh_generation
            .load(Ordering::Acquire),
        refresh_generation
    );
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Connecting
    );
}

#[test]
fn stale_refresh_cannot_overwrite_a_newer_ready_generation() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "preview",
        Vec::new(),
    ));
    let reserved = Arc::new(Barrier::new(2));
    let resume = Arc::new(Barrier::new(2));
    let old_workspace = workspace.clone();
    let old_reserved = Arc::clone(&reserved);
    let old_resume = Arc::clone(&resume);
    let old = thread::spawn(move || {
        let cancellation = CancellationToken::new();
        let generation = reserve_refresh(&old_workspace.scene.runtime, &cancellation);
        old_reserved.wait();
        old_resume.wait();
        let published = publish_refresh(&old_workspace.scene.runtime, generation, || {
            set_scene_state(&old_workspace.scene, WorkspaceContent::Loading);
        });
        (generation, cancellation, published)
    });

    reserved.wait();
    let current_cancellation = CancellationToken::new();
    let current_generation = begin_refresh(
        &workspace.scene,
        &current_cancellation,
        RefreshPresentation::Connecting,
    );
    assert!(publish_refresh(
        &workspace.scene.runtime,
        current_generation,
        || set_scene_state(
            &workspace.scene,
            WorkspaceContent::Ready {
                endpoint: "current".to_owned(),
                sessions: Vec::new(),
            },
        )
    ));
    resume.wait();
    let (old_generation, old_cancellation, old_published) =
        old.join().expect("stale refresh thread");

    assert!(old_cancellation.is_cancelled());
    assert!(!old_published);
    assert!(current_generation > old_generation);
    assert_eq!(
        workspace
            .scene
            .runtime
            .refresh_generation
            .load(Ordering::Acquire),
        current_generation
    );
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Ready { endpoint, .. } if endpoint == "current"
    ));
}

#[test]
fn stale_retry_rejects_detach_followed_by_a_new_attachment() {
    let attachment = Arc::new(Mutex::new(AttachmentState::new()));
    let old_generation = attachment
        .lock()
        .expect("attachment lock")
        .reserve("old", AttachTerm::Xterm256Color)
        .expect("reserve old attachment");
    let exit_captured = Arc::new(Barrier::new(2));
    let retry_resumed = Arc::new(Barrier::new(2));
    let old_attachment = Arc::clone(&attachment);
    let old_exit_captured = Arc::clone(&exit_captured);
    let old_retry_resumed = Arc::clone(&retry_resumed);
    let old_retry = thread::spawn(move || {
        old_exit_captured.wait();
        old_retry_resumed.wait();
        old_attachment
            .lock()
            .expect("attachment lock")
            .promote_if_current(old_generation, AttachTerm::Xterm)
    });

    exit_captured.wait();
    {
        let mut attachment = attachment.lock().expect("attachment lock");
        attachment.invalidate();
        attachment
            .reserve("new", AttachTerm::Xterm256Color)
            .expect("reserve new attachment");
    }
    retry_resumed.wait();

    assert!(!old_retry.join().expect("stale retry thread"));
    let attachment = attachment.lock().expect("attachment lock");
    let active = attachment.active().expect("new attachment remains active");
    assert_eq!(active.request, "new");
    assert_eq!(active.term, AttachTerm::Xterm256Color);
}

#[test]
fn stale_spawn_failure_cannot_clear_a_new_attachment() {
    let attachment = Arc::new(Mutex::new(AttachmentState::new()));
    let old_generation = attachment
        .lock()
        .expect("attachment lock")
        .reserve("old", AttachTerm::Xterm256Color)
        .expect("reserve old attachment");
    let failure_observed = Arc::new(Barrier::new(2));
    let cleanup_resumed = Arc::new(Barrier::new(2));
    let old_attachment = Arc::clone(&attachment);
    let old_failure_observed = Arc::clone(&failure_observed);
    let old_cleanup_resumed = Arc::clone(&cleanup_resumed);
    let old_cleanup = thread::spawn(move || {
        old_failure_observed.wait();
        old_cleanup_resumed.wait();
        old_attachment
            .lock()
            .expect("attachment lock")
            .clear_if_current(old_generation)
    });

    failure_observed.wait();
    {
        let mut attachment = attachment.lock().expect("attachment lock");
        attachment.invalidate();
        attachment
            .reserve("new", AttachTerm::Xterm256Color)
            .expect("reserve new attachment");
    }
    cleanup_resumed.wait();

    assert!(!old_cleanup.join().expect("stale cleanup thread"));
    assert_eq!(
        attachment
            .lock()
            .expect("attachment lock")
            .active()
            .expect("new attachment remains active")
            .request,
        "new"
    );
}

#[test]
fn worker_publication_and_generation_are_captured_atomically() {
    let worker = Arc::new(Mutex::new(WorkerState::new()));
    worker.lock().expect("worker lock").publish("old");
    let drain_ready = Arc::new(Barrier::new(2));
    let drain_resumed = Arc::new(Barrier::new(2));
    let draining_worker = Arc::clone(&worker);
    let draining_ready = Arc::clone(&drain_ready);
    let draining_resumed = Arc::clone(&drain_resumed);
    let drain = thread::spawn(move || {
        draining_ready.wait();
        draining_resumed.wait();
        let worker = draining_worker.lock().expect("worker lock");
        worker
            .active_with_generation()
            .map(|(worker, generation)| (*worker, generation))
    });

    drain_ready.wait();
    let published_generation = worker.lock().expect("worker lock").publish("new");
    drain_resumed.wait();

    assert_eq!(
        drain.join().expect("drain thread"),
        Some(("new", published_generation))
    );
}

#[test]
fn stale_remote_exit_generation_cannot_invalidate_a_replacement_worker() {
    let mut worker = WorkerState::new();
    let exited_generation = worker.publish("remote client");
    let replacement_generation = worker.publish("local replacement");

    assert_eq!(worker.invalidate_if_generation(exited_generation), None);
    assert_eq!(worker.active(), Some(&"local replacement"));
    assert_eq!(worker.generation(), replacement_generation);
}

#[test]
fn remote_presentation_identity_survives_only_a_same_route_lease_renewal() {
    let identity = session::SessionIdentity::new(42, "$1", 100);
    let mut key = RemotePresentationKey {
        host_id: "ssh:studio".to_owned(),
        endpoint: "studio.example".to_owned(),
        route_identity: "route-a".to_owned(),
        lease_generation: 7,
        session_identity: RemoteSessionIdentity::Tmux(identity.clone()),
    };
    let sessions = vec![session::DiscoveredSession::new("renamed", identity, 1)];

    assert_eq!(
        key.reconcile(
            "studio.example",
            "route-a",
            8,
            Some(RemoteInventory {
                tmux: Some(&sessions),
                herdr: Some(&[]),
                zellij: Some(&[]),
            }),
        ),
        RemoteReconcile::Found(SessionKind::Tmux, "renamed".to_owned())
    );
    assert_eq!(key.lease_generation, 8);
    assert_eq!(
        key.reconcile(
            "studio.example",
            "route-a",
            9,
            Some(RemoteInventory {
                tmux: None,
                herdr: Some(&[]),
                zellij: Some(&[]),
            }),
        ),
        RemoteReconcile::Unknown
    );
    assert_eq!(key.lease_generation, 9);
    assert_eq!(
        key.reconcile(
            "studio.example",
            "route-b",
            10,
            Some(RemoteInventory {
                tmux: Some(&sessions),
                herdr: Some(&[]),
                zellij: Some(&[]),
            }),
        ),
        RemoteReconcile::Stale
    );
    assert_eq!(key.lease_generation, 9);
}

#[test]
fn failed_remote_backend_inventory_preserves_known_presentation_identity() {
    let mut key = RemotePresentationKey {
        host_id: "ssh:studio".to_owned(),
        endpoint: "studio.example".to_owned(),
        route_identity: "route-a".to_owned(),
        lease_generation: 7,
        session_identity: RemoteSessionIdentity::Herdr {
            name: "review".to_owned(),
            is_default: false,
            session_directory: "/tmp/herdr/review".to_owned(),
            socket_path: "/tmp/herdr/review.sock".to_owned(),
        },
    };

    assert_eq!(
        key.reconcile(
            "studio.example",
            "route-a",
            8,
            Some(RemoteInventory {
                tmux: Some(&[]),
                herdr: None,
                zellij: Some(&[]),
            }),
        ),
        RemoteReconcile::Unknown
    );
    assert_eq!(key.lease_generation, 8);
    assert_eq!(
        key.reconcile(
            "studio.example",
            "route-a",
            9,
            Some(RemoteInventory {
                tmux: Some(&[]),
                herdr: Some(&[]),
                zellij: Some(&[]),
            }),
        ),
        RemoteReconcile::Stale
    );
}

#[test]
fn worker_publication_applies_geometry_that_changed_during_launch() {
    let initial = default_terminal_geometry();
    let latest = TerminalGeometry {
        grid: GridSize::new(132, 43).expect("valid grid"),
        pixels: PixelSize::new(1_320, 860),
        sequence: initial.sequence + 1,
    };
    let geometry = Mutex::new(latest);
    let workers = Mutex::new(WorkerState::new());
    let applied = Mutex::new(None);

    let generation = publish_worker_at_latest_geometry(
        &geometry,
        &workers,
        "client",
        initial,
        |_, geometry| {
            *applied.lock().expect("applied geometry lock") = Some(geometry);
            Ok::<(), ()>(())
        },
        |_| {},
    )
    .expect("publish worker");

    assert_eq!(
        *applied.lock().expect("applied geometry lock"),
        Some(latest)
    );
    assert_eq!(
        workers
            .lock()
            .expect("worker lock")
            .active_with_generation(),
        Some((&"client", generation))
    );
}

#[test]
fn worker_publication_holds_geometry_until_worker_is_visible() {
    let initial = default_terminal_geometry();
    let latest = TerminalGeometry {
        sequence: initial.sequence + 1,
        ..initial
    };
    let geometry = Arc::new(Mutex::new(latest));
    let workers = Arc::new(Mutex::new(WorkerState::new()));
    let (locked_sender, locked_receiver) = std::sync::mpsc::channel();
    let (release_sender, release_receiver) = std::sync::mpsc::channel();
    let publishing_geometry = Arc::clone(&geometry);
    let publishing_workers = Arc::clone(&workers);
    let publisher = thread::spawn(move || {
        publish_worker_at_latest_geometry(
            &publishing_geometry,
            &publishing_workers,
            "client",
            initial,
            |_, _| {
                locked_sender.send(()).expect("signal held locks");
                release_receiver.recv().expect("resume publication");
                Ok::<(), ()>(())
            },
            |_| {},
        )
        .expect("publish worker")
    });

    locked_receiver.recv().expect("publication reached resize");
    let geometry_was_locked = geometry.try_lock().is_err();
    let worker_was_locked = workers.try_lock().is_err();
    release_sender.send(()).expect("release publication");
    let _generation = publisher.join().expect("publisher thread");

    assert!(geometry_was_locked, "geometry lock was released too early");
    assert!(worker_was_locked, "worker lock was released too early");
}

#[test]
fn worker_publication_reconciles_settings_changed_during_launch() {
    let initial = default_terminal_geometry();
    let latest = TerminalGeometry {
        sequence: initial.sequence + 1,
        ..initial
    };
    let geometry = Arc::new(Mutex::new(latest));
    let workers = Arc::new(Mutex::new(WorkerState::new()));
    let cursor_default = Arc::new(AtomicU8::new(0));
    let published_cursor = Arc::new(AtomicU8::new(0));
    let (launching_sender, launching_receiver) = std::sync::mpsc::channel();
    let (release_sender, release_receiver) = std::sync::mpsc::channel();
    let publishing_geometry = Arc::clone(&geometry);
    let publishing_workers = Arc::clone(&workers);
    let publishing_default = Arc::clone(&cursor_default);
    let publishing_cursor = Arc::clone(&published_cursor);
    let publisher = thread::spawn(move || {
        publish_worker_at_latest_geometry(
            &publishing_geometry,
            &publishing_workers,
            publishing_cursor,
            initial,
            |_, _| {
                launching_sender.send(()).expect("signal launch in flight");
                release_receiver.recv().expect("finish launch");
                Ok::<(), ()>(())
            },
            |worker| {
                worker.store(
                    publishing_default.load(Ordering::Acquire),
                    Ordering::Release,
                );
            },
        )
        .expect("publish worker")
    });

    launching_receiver
        .recv()
        .expect("launch reached publication");
    cursor_default.store(2, Ordering::Release);
    release_sender.send(()).expect("release publication");
    let _generation = publisher.join().expect("publisher thread");

    assert_eq!(published_cursor.load(Ordering::Acquire), 2);
}

#[test]
fn replacement_fallback_survives_publication_until_the_client_is_confirmed() {
    let fallback = fallback_fixture(
        "boot-id",
        42,
        session::SessionIdentity::new(100, "$1", 200),
        1,
    );
    let mut attachment = AttachmentState::new();
    let attachment_generation = attachment
        .reserve_with_fallback(
            "replacement",
            AttachTerm::Xterm256Color,
            Some(fallback.clone()),
        )
        .expect("reserve replacement attachment");
    let mut worker = WorkerState::new();
    let worker_generation = worker.publish("replacement client");

    let fallback_for_exit = attachment.fallback_if_current(attachment_generation);
    assert_eq!(
        fallback_for_exit,
        Some(fallback.clone()),
        "publishing the replacement must not consume its fallback"
    );

    assert!(claim_terminal_exit(
        &mut attachment,
        &mut worker,
        attachment_generation,
        worker_generation,
        false,
    ));
    assert_eq!(fallback_for_exit, Some(fallback));
}

#[test]
fn confirmed_replacement_releases_its_fallback() {
    let fallback = fallback_fixture(
        "boot-id",
        42,
        session::SessionIdentity::new(100, "$1", 200),
        1,
    );
    let mut attachment = AttachmentState::new();
    let generation = attachment
        .reserve_with_fallback("replacement", AttachTerm::Xterm256Color, Some(fallback))
        .expect("reserve replacement attachment");

    assert!(attachment.confirm_if_current(generation));
    assert_eq!(attachment.fallback_if_current(generation), None);
}

#[test]
fn duplicate_exit_claim_cannot_invalidate_the_retry_worker() {
    let attachment = Arc::new(Mutex::new(AttachmentState::new()));
    let attachment_generation = attachment
        .lock()
        .expect("attachment lock")
        .reserve("request", AttachTerm::Xterm256Color)
        .expect("reserve attachment");
    let worker = Arc::new(Mutex::new(WorkerState::new()));
    let worker_generation = worker.lock().expect("worker lock").publish("client");
    let exit_claimed = Arc::new(Barrier::new(2));

    let exiting_attachment = Arc::clone(&attachment);
    let exiting_worker = Arc::clone(&worker);
    let exiting_claimed = Arc::clone(&exit_claimed);
    let exit = thread::spawn(move || {
        let mut attachment = exiting_attachment.lock().expect("attachment lock");
        let mut worker = exiting_worker.lock().expect("worker lock");
        let claimed = claim_terminal_exit(
            &mut attachment,
            &mut worker,
            attachment_generation,
            worker_generation,
            true,
        );
        exiting_claimed.wait();
        claimed
    });

    let disconnected_attachment = Arc::clone(&attachment);
    let disconnected_worker = Arc::clone(&worker);
    let disconnect = thread::spawn(move || {
        exit_claimed.wait();
        let mut attachment = disconnected_attachment.lock().expect("attachment lock");
        let mut worker = disconnected_worker.lock().expect("worker lock");
        claim_terminal_exit(
            &mut attachment,
            &mut worker,
            attachment_generation,
            worker_generation,
            false,
        )
    });

    assert!(exit.join().expect("exit drain"));
    assert!(!disconnect.join().expect("disconnect drain"));
    assert!(
        attachment
            .lock()
            .expect("attachment lock")
            .is_current(attachment_generation)
    );
    assert!(worker.lock().expect("worker lock").active().is_none());
}

#[test]
fn received_exit_is_claimed_before_a_competing_disconnect() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "test",
        Vec::new(),
    ));
    let attachment = Arc::new(Mutex::new(AttachmentState::new()));
    let attachment_generation = attachment
        .lock()
        .expect("attachment lock")
        .reserve("request", AttachTerm::Xterm256Color)
        .expect("reserve attachment");
    let worker = Arc::new(Mutex::new(WorkerState::new()));
    let worker_generation = worker.lock().expect("worker lock").publish("client");
    let (exit_received_tx, exit_received_rx) = std::sync::mpsc::channel();
    let (disconnect_waiting_tx, disconnect_waiting_rx) = std::sync::mpsc::channel();
    let allow_exit_claim = Arc::new(Barrier::new(2));

    let exiting_scene = Arc::clone(&workspace.scene);
    let exiting_attachment = Arc::clone(&attachment);
    let exiting_worker = Arc::clone(&worker);
    let exiting_allow_claim = Arc::clone(&allow_exit_claim);
    let exit = thread::spawn(move || {
        let _drain = exiting_scene
            .runtime
            .event_drain
            .lock()
            .expect("event drain lock");
        exit_received_tx.send(()).expect("signal exit received");
        exiting_allow_claim.wait();
        let mut attachment = exiting_attachment.lock().expect("attachment lock");
        let mut worker = exiting_worker.lock().expect("worker lock");
        claim_terminal_exit(
            &mut attachment,
            &mut worker,
            attachment_generation,
            worker_generation,
            true,
        )
    });

    let disconnected_scene = Arc::clone(&workspace.scene);
    let disconnected_attachment = Arc::clone(&attachment);
    let disconnected_worker = Arc::clone(&worker);
    let disconnect = thread::spawn(move || {
        exit_received_rx.recv().expect("wait for exit event");
        disconnect_waiting_tx
            .send(())
            .expect("signal disconnect waiting");
        let _drain = disconnected_scene
            .runtime
            .event_drain
            .lock()
            .expect("event drain lock");
        let mut attachment = disconnected_attachment.lock().expect("attachment lock");
        let mut worker = disconnected_worker.lock().expect("worker lock");
        claim_terminal_exit(
            &mut attachment,
            &mut worker,
            attachment_generation,
            worker_generation,
            false,
        )
    });

    disconnect_waiting_rx
        .recv()
        .expect("wait for disconnect contender");
    allow_exit_claim.wait();

    assert!(exit.join().expect("exit drain"));
    assert!(!disconnect.join().expect("disconnect drain"));
    assert!(
        attachment
            .lock()
            .expect("attachment lock")
            .is_current(attachment_generation)
    );
}

#[test]
fn inventory_refresh_does_not_replace_an_active_terminal() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let size = GridSize::new(80, 24).expect("valid grid");
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "work".to_owned(),
            kind: SessionKind::Tmux,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
        },
    );
    let revision = workspace.snapshot().revision();

    set_inventory_state(
        &workspace.scene.runtime,
        &WorkspaceContent::Ready {
            endpoint: "Ubuntu".to_owned(),
            sessions: vec![SessionItem::new("other", 0)],
        },
    );

    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Terminal { session, .. } if session == "work"
    ));
    assert_eq!(workspace.snapshot().revision(), revision);

    workspace.restore_inventory_state();

    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Ready { sessions, .. }
            if sessions.len() == 1 && sessions[0].name() == "other"
    ));
}

#[test]
fn switching_to_the_active_session_is_a_no_op() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let size = GridSize::new(80, 24).expect("valid grid");
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "work".to_owned(),
            kind: SessionKind::Tmux,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
        },
    );

    workspace
        .switch_session(&SessionSelection::new("wsl", "Ubuntu", "work"))
        .expect("active session remains selected");

    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Terminal { session, .. } if session == "work"
    ));

    assert!(
        workspace
            .switch_session(&SessionSelection::new("wsl", "Debian", "work"))
            .is_err(),
        "an equal name on a different endpoint is not the active selection"
    );
}

#[test]
fn a_different_selection_supersedes_an_inflight_attachment_and_carries_its_fallback() {
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let workspace = Workspace::application(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
    );
    let host = WslHost::new(
        config,
        Arc::new(StdCommandRunner) as SharedCommandRunner,
        executable,
    );
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![
            session::DiscoveredSession::new(
                "opening",
                session::SessionIdentity::new(100, "$1", 200),
                0,
            ),
            session::DiscoveredSession::new(
                "selected",
                session::SessionIdentity::new(100, "$2", 201),
                0,
            ),
        ],
    );
    *workspace
        .scene
        .runtime
        .host
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Published::new(
        HostContext {
            host,
            snapshot: snapshot.clone(),
        },
        0,
    ));
    set_inventory_state(&workspace.scene.runtime, &ready_content(&snapshot));
    let opening = captured_request(&workspace, "opening");
    let selected = captured_request(&workspace, "selected");
    let opening_navigation = workspace.begin_navigation();
    let mut fallback = fallback_fixture(
        "boot-id",
        42,
        session::SessionIdentity::new(100, "$3", 202),
        opening_navigation,
    );
    fallback.target = opening.presentation_key();
    workspace
        .scene
        .attachment
        .lock()
        .expect("attachment")
        .reserve_with_fallback(opening, AttachTerm::Xterm256Color, Some(fallback.clone()))
        .expect("reserve opening attachment");
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "opening".to_owned(),
            kind: SessionKind::Tmux,
        },
    );
    let carried_fallback = workspace
        .supersede_inflight_attachment()
        .expect("supersede opening attachment");
    let selected_navigation = workspace.begin_navigation();
    let carried_fallback = carried_fallback.map(|presentation| FallbackAuthority {
        presentation,
        target: selected.presentation_key(),
        navigation_generation: selected_navigation,
    });
    let selected_generation = workspace
        .scene
        .attachment
        .lock()
        .expect("attachment")
        .reserve_with_fallback(selected, AttachTerm::Xterm256Color, carried_fallback)
        .expect("reserve selected attachment");
    let attachment = workspace.scene.attachment.lock().expect("attachment");
    let active = attachment.active().expect("selected attachment active");
    assert_eq!(
        attachment.fallback_if_current(selected_generation).as_ref(),
        Some(&FallbackAuthority {
            presentation: fallback.presentation,
            target: active.request.presentation_key(),
            navigation_generation: selected_navigation,
        })
    );
}

#[test]
fn switching_sessions_cancels_pending_creation_and_restores_inventory() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("selected", 0)],
    ));
    let creation_navigation = workspace.begin_navigation();
    let cancellation = CancellationToken::new();
    *workspace
        .scene
        .pending_creation
        .lock()
        .expect("pending creation") = Some(PendingCreation {
        navigation_generation: creation_navigation,
        previous: None,
        cancellation: cancellation.clone(),
        herdr_operation: None,
    });
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "creating".to_owned(),
            kind: SessionKind::Tmux,
        },
    );

    let _switch_navigation = workspace.begin_navigation();
    let fallback = workspace
        .supersede_inflight_attachment()
        .expect("switch supersedes pending creation");

    assert_eq!(fallback, None);
    assert!(cancellation.is_cancelled());
    assert!(
        workspace
            .scene
            .pending_creation
            .lock()
            .expect("pending creation")
            .is_none()
    );
    restore_inventory_after_creation_failure(
        &workspace.scene,
        None,
        creation_navigation,
        "stale creation failure".to_owned(),
    );
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Ready { sessions, .. }
            if sessions.iter().any(|session| session.name() == "selected")
    ));
    assert_eq!(workspace.snapshot().notice(), None);
}

#[test]
fn remote_navigation_cancels_and_settles_pending_local_creation() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("selected", 0)],
    ));
    let creation_navigation = workspace.begin_navigation();
    let cancellation = CancellationToken::new();
    *workspace
        .scene
        .pending_creation
        .lock()
        .expect("pending creation") = Some(PendingCreation {
        navigation_generation: creation_navigation,
        previous: None,
        cancellation: cancellation.clone(),
        herdr_operation: None,
    });
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "creating".to_owned(),
            kind: SessionKind::Tmux,
        },
    );

    workspace.begin_navigation();
    workspace
        .settle_local_navigation_before_remote()
        .expect("remote navigation settles local creation");

    assert!(cancellation.is_cancelled());
    assert!(
        workspace
            .scene
            .pending_creation
            .lock()
            .expect("pending creation")
            .is_none()
    );
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Ready { sessions, .. }
            if sessions.iter().any(|session| session.name() == "selected")
    ));
}

#[test]
fn detaching_during_creation_cancels_the_task_and_restores_inventory() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("existing", 0)],
    ));
    let creation_navigation = workspace.begin_navigation();
    let cancellation = CancellationToken::new();
    *workspace
        .scene
        .pending_creation
        .lock()
        .expect("pending creation") = Some(PendingCreation {
        navigation_generation: creation_navigation,
        previous: None,
        cancellation: cancellation.clone(),
        herdr_operation: None,
    });
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Attaching {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "creating".to_owned(),
            kind: SessionKind::Tmux,
        },
    );

    workspace.detach();

    assert!(cancellation.is_cancelled());
    assert!(
        workspace
            .scene
            .pending_creation
            .lock()
            .expect("pending creation")
            .is_none()
    );
    restore_inventory_after_creation_failure(
        &workspace.scene,
        None,
        creation_navigation,
        "stale creation failure".to_owned(),
    );
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Ready { sessions, .. }
            if sessions.iter().any(|session| session.name() == "existing")
    ));
    assert_eq!(workspace.snapshot().notice(), None);
}

#[cfg(windows)]
#[test]
fn stale_kill_identity_results_cannot_publish_confirmation() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(StdCommandRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let pending = |generation| PendingKill {
        generation,
        selection: SessionSelection::new("wsl", "Ubuntu", "work"),
        host: host.clone(),
        target: KillTarget::Tmux(Arc::new(LiveSessionTarget::test_fixture(
            &snapshot,
            "work",
            session::SessionIdentity::new(100, "$1", 200),
        ))),
    };

    workspace.scene.kill_generation.store(2, Ordering::Release);
    assert!(!publish_pending_kill(&workspace.scene, pending(1)));
    assert_eq!(workspace.session_kill_confirmation(), None);

    workspace.scene.kill_generation.store(3, Ordering::Release);
    assert!(publish_pending_kill(&workspace.scene, pending(3)));
    assert!(workspace.session_kill_confirmation().is_some());
    workspace
        .request_session_kill(&SessionSelection::new("wsl", "Ubuntu", "missing"))
        .expect_err("new invalid request still supersedes old confirmation");
    assert_eq!(workspace.session_kill_confirmation(), None);
}

#[test]
fn invalid_switch_target_does_not_detach_the_active_session() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let size = GridSize::new(80, 24).expect("valid grid");
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "work".to_owned(),
            kind: SessionKind::Tmux,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
        },
    );

    assert!(
        workspace
            .switch_session(&SessionSelection::new("wsl", "Ubuntu", "missing"))
            .is_err()
    );
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Terminal { session, .. } if session == "work"
    ));
}

#[cfg(windows)]
#[test]
fn killed_presentation_cleanup_never_detaches_a_different_active_session() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let killed_identity = session::SessionIdentity::new(100, "$1", 200);
    let active_identity = session::SessionIdentity::new(100, "$2", 201);
    let active_request = attach_request_fixture(&snapshot, active_identity.clone(), "active");
    workspace
        .scene
        .attachment
        .lock()
        .expect("attachment")
        .reserve(active_request, AttachTerm::Xterm256Color)
        .expect("reserve active attachment");
    let size = GridSize::new(80, 24).expect("valid grid");
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "active".to_owned(),
            kind: SessionKind::Tmux,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
        },
    );

    workspace.finish_killed_presentation(
        snapshot.endpoint(),
        snapshot.runtime(),
        &killed_identity,
        "killed",
        None,
    );

    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Terminal { session, .. } if session == "active"
    ));
    assert_eq!(
        workspace
            .scene
            .attachment
            .lock()
            .expect("attachment")
            .active()
            .expect("active attachment")
            .request
            .target,
        AttachTarget::Tmux(active_identity)
    );
}

#[cfg(windows)]
#[test]
fn zellij_kill_suppression_keeps_active_recovery_authority() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let request = zellij_attach_request_fixture(&snapshot, "work");
    workspace
        .scene
        .attachment
        .lock()
        .expect("attachment")
        .reserve(request, AttachTerm::Xterm256Color)
        .expect("reserve active attachment");
    let size = GridSize::new(80, 24).expect("valid grid");
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "work".to_owned(),
            kind: SessionKind::Zellij,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
        },
    );

    let suppressed = workspace
        .close_zellij_presentations(snapshot.endpoint(), snapshot.runtime(), "work")
        .into_iter()
        .next()
        .expect("matching presentation is recoverable");

    assert_eq!(
        suppressed.active_selection,
        Some(SessionSelection::zellij("wsl", "Ubuntu", "work"))
    );
    assert!(
        workspace
            .scene
            .attachment
            .lock()
            .expect("attachment")
            .active()
            .is_none()
    );
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Ready { .. }
    ));
}

#[test]
fn refresh_failure_is_deferred_until_the_terminal_closes() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let size = GridSize::new(80, 24).expect("valid grid");
    set_scene_state(
        &workspace.scene,
        WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "work".to_owned(),
            kind: SessionKind::Tmux,
            presentation_id: 1,
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(1, size))),
        },
    );

    set_inventory_state(
        &workspace.scene.runtime,
        &WorkspaceContent::Error {
            message: "WSL is unavailable".to_owned(),
        },
    );
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Terminal { .. }
    ));

    workspace.restore_inventory_state();

    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Error { message } if message == "WSL is unavailable"
    ));
}

#[test]
fn refresh_budgets_distinguish_cold_start_from_retry() {
    assert_eq!(refresh_budget(1), Duration::from_secs(45));
    assert_eq!(refresh_budget(2), Duration::from_secs(30));
}

#[test]
fn blocked_host_discovery_does_not_block_snapshot_reads() {
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot",
        42,
        vec![session::DiscoveredSession::new(
            "work",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    );
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let discovery = Arc::new(BlockingDiscovery {
        snapshot,
        entered: Mutex::new(Some(entered_tx)),
        release: Mutex::new(release_rx),
    });
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        discovery,
        Arc::new(ThreadRefreshRuntime),
    );
    workspace.connect_enabled_hosts().expect("start refresh");
    entered_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("discovery reached blocking host read");

    let snapshot_workspace = workspace.clone();
    let (snapshot_tx, snapshot_rx) = mpsc::sync_channel(1);
    let snapshot_reader = thread::spawn(move || {
        let snapshot = snapshot_workspace.snapshot();
        snapshot_tx
            .send(snapshot.hosts()[0].connection())
            .expect("publish snapshot result");
    });
    let connection = snapshot_rx
        .recv_timeout(Duration::from_millis(250))
        .expect("snapshot remains responsive during host I/O");
    assert_eq!(connection, HostConnectionState::Connecting);

    release_tx.send(()).expect("release host discovery");
    snapshot_reader.join().expect("snapshot reader");
    let deadline = std::time::Instant::now() + Duration::from_secs(1);
    while workspace.snapshot().hosts()[0].connection() != HostConnectionState::Ready
        && std::time::Instant::now() < deadline
    {
        thread::yield_now();
    }
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Ready
    );
}

#[test]
fn refresh_deadlines_and_retry_order_are_manually_driven() {
    let runtime = Arc::new(ManualRefreshRuntime::default());
    let discovery = Arc::new(FixedDiscovery::new(HostSnapshot::test_fixture(
        "Ubuntu",
        "boot",
        42,
        vec![session::DiscoveredSession::new(
            "work",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    )));
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        discovery,
        runtime.clone(),
    );

    workspace.connect_enabled_hosts().expect("start refresh");
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Connecting
    );
    assert_eq!(runtime.deadline_delays(), vec![Duration::from_secs(45)]);

    runtime.run_next_deadline();
    assert_eq!(
        workspace.snapshot().hosts()[0]
            .diagnostic()
            .expect("timeout diagnostic")
            .kind(),
        DiagnosticKind::Timeout
    );

    set_scene_state(&workspace.scene, WorkspaceContent::Shell);
    workspace.refresh().expect("start retry");
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Shell
    ));
    assert_eq!(runtime.deadline_delays(), vec![Duration::from_secs(30)]);
    runtime.run_next_work();
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Connecting
    );
    runtime.run_next_work();

    let snapshot = workspace.snapshot();
    assert_eq!(snapshot.hosts()[0].connection(), HostConnectionState::Ready);
    assert_eq!(snapshot.hosts()[0].sessions()[0].name(), "work");

    runtime.run_next_deadline();
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Ready
    );
}

fn herdr_workspace_with_sessions(
    herdr_sessions: Vec<session::HerdrSessionRecord>,
) -> (Workspace, Arc<ManualRefreshRuntime>) {
    herdr_workspace_with_sessions_and_term(herdr_sessions, AttachTerm::Xterm256Color)
}

fn herdr_workspace_with_sessions_and_term(
    herdr_sessions: Vec<session::HerdrSessionRecord>,
    term: AttachTerm,
) -> (Workspace, Arc<ManualRefreshRuntime>) {
    let runtime = Arc::new(ManualRefreshRuntime::default());
    let snapshot = HostSnapshot::test_fixture_with_herdr(
        "Ubuntu",
        "boot",
        42,
        vec![session::DiscoveredSession::new(
            "work",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
        HerdrInventory::Available {
            executable: "/opt/herdr/bin/herdr".to_owned(),
            sessions: herdr_sessions,
        },
    )
    .test_fixture_with_creation_term(term);
    let discovery = Arc::new(FixedDiscovery::new(snapshot));
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        discovery,
        runtime.clone(),
    );

    workspace.connect_enabled_hosts().expect("start refresh");
    runtime.run_next_work();
    (workspace, runtime)
}

fn herdr_workspace_fixture() -> (Workspace, Arc<ManualRefreshRuntime>) {
    herdr_workspace_with_sessions(vec![
        session::HerdrSessionRecord::new(
            "default",
            true,
            HerdrSessionState::Running,
            "/tmp/herdr/default",
            "/tmp/herdr/default/herdr.sock",
        ),
        session::HerdrSessionRecord::new(
            "review",
            false,
            HerdrSessionState::Stopped,
            "/tmp/herdr/review",
            "/tmp/herdr/review/herdr.sock",
        ),
    ])
}

#[test]
fn successful_refresh_projects_herdr_without_changing_tmux_readiness() {
    let (workspace, _runtime) = herdr_workspace_fixture();

    let snapshot = workspace.snapshot();
    let host = &snapshot.hosts()[0];
    assert_eq!(host.connection(), HostConnectionState::Ready);
    assert_eq!(host.sessions()[0].name(), "work");
    assert!(host.herdr_available());
    assert_eq!(host.herdr_sessions().len(), 2);
    assert!(host.herdr_sessions()[0].is_default());
    assert_eq!(host.herdr_sessions()[1].state(), HerdrSessionState::Stopped);
    assert!(host.herdr_diagnostic().is_none());
}

#[test]
fn herdr_constructive_requests_use_the_admitted_terminal_capability() {
    let (workspace, _runtime) = herdr_workspace_with_sessions_and_term(
        vec![session::HerdrSessionRecord::new(
            "review",
            false,
            HerdrSessionState::Stopped,
            "/tmp/herdr/review",
            "/tmp/herdr/review/herdr.sock",
        )],
        AttachTerm::Xterm,
    );

    let created = capture_herdr_create_request(
        &workspace.scene,
        "wsl",
        "Ubuntu",
        HerdrSessionName::parse("created").expect("valid name"),
    )
    .expect("capture creation");
    let restarted = capture_herdr_restart_request(
        &workspace.scene,
        &SessionSelection::herdr("wsl", "Ubuntu", "review"),
    )
    .expect("capture restart");

    assert_eq!(created.term, AttachTerm::Xterm);
    assert_eq!(restarted.term, AttachTerm::Xterm);
}

#[test]
fn wsl_capture_rejects_remote_host_ids_even_when_inventory_identity_collides() {
    let (workspace, _runtime) = herdr_workspace_fixture();
    let remote_host = "ssh:collision";
    *workspace
        .scene
        .selected_host
        .write()
        .expect("selected host") = Some(remote_host.to_owned());

    assert!(
        capture_kill_request(
            &workspace.scene,
            &SessionSelection::new(remote_host, "Ubuntu", "work"),
            1,
        )
        .is_err()
    );
    assert!(
        capture_herdr_lifecycle(
            &workspace.scene,
            &SessionSelection::herdr(remote_host, "Ubuntu", "default"),
            HerdrLifecycleAction::Stop,
            1,
        )
        .is_err()
    );
    assert!(
        capture_create_request(
            &workspace.scene,
            remote_host,
            "Ubuntu",
            SessionName::parse("created").expect("valid tmux name"),
        )
        .is_err()
    );
    assert!(
        capture_herdr_create_request(
            &workspace.scene,
            remote_host,
            "Ubuntu",
            HerdrSessionName::parse("created").expect("valid Herdr name"),
        )
        .is_err()
    );
    assert!(
        capture_zellij_create_request(
            &workspace.scene,
            remote_host,
            "Ubuntu",
            ZellijSessionName::parse("created").expect("valid Zellij name"),
        )
        .is_err()
    );
    assert!(
        capture_herdr_restart_request(
            &workspace.scene,
            &SessionSelection::herdr(remote_host, "Ubuntu", "review"),
        )
        .is_err()
    );
}

#[test]
fn unavailable_hosts_reject_herdr_mutations_and_preserve_confirmation() {
    let (workspace, _runtime) = herdr_workspace_fixture();
    let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
    workspace
        .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
        .expect("prepare stop while ready");
    workspace
        .scene
        .runtime
        .hosts
        .write()
        .expect("hosts")
        .iter_mut()
        .find(|host| host.id == "wsl")
        .expect("WSL host")
        .connection = HostConnectionState::Unavailable;

    let error = workspace
        .confirm_herdr_lifecycle()
        .expect_err("unavailable host must block confirmed mutation");
    assert!(error.to_string().contains("connect the WSL host"));
    assert!(workspace.herdr_lifecycle_confirmation().is_some());

    let stopped = SessionSelection::herdr("wsl", "Ubuntu", "review");
    assert!(workspace.restart_herdr_session(&stopped).is_err());
    workspace.cancel_herdr_lifecycle();
    assert!(
        workspace
            .request_herdr_lifecycle(&stopped, HerdrLifecycleAction::Delete)
            .is_err()
    );
}

#[test]
fn in_flight_herdr_lifecycle_is_visible_and_rejects_duplicates() {
    let (workspace, _runtime) = herdr_workspace_fixture();

    let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
    workspace
        .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
        .expect("running session may be stopped");
    assert_eq!(
        workspace
            .herdr_lifecycle_confirmation()
            .expect("stop confirmation")
            .action(),
        HerdrLifecycleAction::Stop
    );
    let stop_generation = {
        let mut lifecycle = workspace
            .scene
            .runtime
            .herdr_lifecycle
            .lock()
            .expect("lifecycle state");
        let pending = workspace
            .scene
            .pending_herdr_lifecycle
            .lock()
            .expect("pending lifecycle")
            .take()
            .expect("pending stop");
        assert!(lifecycle.start(&pending));
        pending.generation
    };
    assert_eq!(
        workspace.snapshot().hosts()[0].herdr_sessions()[0].lifecycle_action(),
        Some(HerdrLifecycleAction::Stop)
    );
    assert!(
        workspace
            .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
            .is_err(),
        "a duplicate lifecycle action is rejected while Stop is in flight"
    );
    workspace
        .scene
        .runtime
        .herdr_lifecycle
        .lock()
        .expect("lifecycle state")
        .finish(stop_generation);
    assert_eq!(
        workspace.snapshot().hosts()[0].herdr_sessions()[0].lifecycle_action(),
        None
    );

    let stopped = SessionSelection::herdr("wsl", "Ubuntu", "review");
    let restart = capture_herdr_restart_request(&workspace.scene, &stopped)
        .expect("stopped session may restart");
    assert!(matches!(
        restart.precondition,
        HerdrLaunchPrecondition::Stopped(record) if record.name() == "review"
    ));
    workspace
        .request_herdr_lifecycle(&stopped, HerdrLifecycleAction::Delete)
        .expect("stopped named session may be deleted");
    assert_eq!(
        workspace
            .herdr_lifecycle_confirmation()
            .expect("delete confirmation")
            .action(),
        HerdrLifecycleAction::Delete
    );
}

#[test]
fn pending_herdr_launch_is_visible_and_rejects_duplicate_operations() {
    let (workspace, _runtime) = herdr_workspace_fixture();
    let stopped = SessionSelection::herdr("wsl", "Ubuntu", "review");
    let request = capture_herdr_restart_request(&workspace.scene, &stopped)
        .expect("stopped session may restart");
    let key = request.operation_key();

    assert!(
        workspace
            .scene
            .runtime
            .herdr_lifecycle
            .lock()
            .expect("lifecycle state")
            .reserve_launch(&key)
    );

    let snapshot = workspace.snapshot();
    let review = snapshot.hosts()[0]
        .herdr_sessions()
        .iter()
        .find(|session| session.name() == "review")
        .expect("review session");
    assert!(review.launch_pending());
    assert!(
        !workspace
            .scene
            .runtime
            .herdr_lifecycle
            .lock()
            .expect("lifecycle state")
            .reserve_launch(&key)
    );
    assert!(
        workspace
            .switch_session(&stopped)
            .expect_err("a pending restart blocks presentation changes")
            .to_string()
            .contains("already starting")
    );
    assert!(
        workspace
            .request_herdr_lifecycle(&stopped, HerdrLifecycleAction::Delete)
            .expect_err("lifecycle mutation is blocked while restart is pending")
            .to_string()
            .contains("still starting")
    );

    finish_herdr_launch(&workspace.scene.runtime, &key);
    assert!(!workspace.snapshot().hosts()[0].herdr_sessions()[1].launch_pending());
}

#[test]
fn failed_herdr_inventory_blocks_fresh_and_mutating_actions() {
    let (workspace, _runtime) = herdr_workspace_fixture();
    set_herdr_inventory(
        &workspace.scene.runtime,
        &HerdrInventory::Failed(
            WslExecutable::from_absolute("wsl.exe").expect_err("relative path is rejected"),
        ),
    );

    let create = capture_herdr_create_request(
        &workspace.scene,
        "wsl",
        "Ubuntu",
        HerdrSessionName::parse("created").expect("valid name"),
    )
    .err()
    .expect("failed inventory blocks creation");
    assert!(create.to_string().contains("refresh Herdr inventory"));

    let stopped = SessionSelection::herdr("wsl", "Ubuntu", "review");
    let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
    assert!(
        workspace
            .switch_session(&running)
            .expect_err("failed inventory blocks a fresh open")
            .to_string()
            .contains("refresh Herdr inventory")
    );
    assert!(
        capture_herdr_restart_request(&workspace.scene, &stopped)
            .err()
            .expect("failed inventory blocks restart")
            .to_string()
            .contains("refresh Herdr inventory")
    );
    assert!(
        workspace
            .request_herdr_lifecycle(&stopped, HerdrLifecycleAction::Delete)
            .expect_err("failed inventory blocks mutation")
            .to_string()
            .contains("refresh Herdr inventory")
    );
}

fn assert_inconclusive_inventory_keeps_lifecycle_fenced(
    workspace: &Workspace,
    fresh: &HostSnapshot,
    reconciliation_floor: u64,
) {
    assert!(
        !reconcile_herdr_lifecycle_fences(
            &workspace.scene.runtime,
            fresh,
            reconciliation_floor,
            true,
        )
        .changed
    );
    let failed = HostSnapshot::test_fixture_with_herdr(
        "Ubuntu",
        "boot",
        42,
        Vec::new(),
        HerdrInventory::Failed(
            WslExecutable::from_absolute("wsl.exe").expect_err("relative path is rejected"),
        ),
    );
    assert!(
        !reconcile_herdr_lifecycle_fences(
            &workspace.scene.runtime,
            &failed,
            reconciliation_floor + 1,
            true,
        )
        .changed
    );
    let unavailable_after_restart = HostSnapshot::test_fixture_with_herdr(
        "Ubuntu",
        "restarted-boot",
        84,
        Vec::new(),
        HerdrInventory::Unavailable,
    );
    assert!(
        !reconcile_herdr_lifecycle_fences(
            &workspace.scene.runtime,
            &unavailable_after_restart,
            reconciliation_floor + 2,
            true,
        )
        .changed
    );
}

#[cfg(windows)]
#[test]
#[allow(
    clippy::too_many_lines,
    reason = "the revocation, hand-off, and re-drive read as one lifecycle"
)]
fn a_herdr_stop_revokes_restarts_and_the_delayed_recovery_re_drives_them() {
    // The Herdr twin of the Zellij revocation test, routed through the
    // uncertain-lifecycle delayed recovery: suppression revokes the
    // restarting registration (so the queued retry launches nothing), the
    // revoked entry survives the DelayedHerdrRecovery hand-off, and the
    // released recovery re-drives a fresh retry in the owning scene.
    let (workspace, _runtime) = herdr_workspace_fixture();
    let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
    let snapshot = workspace
        .scene
        .runtime
        .host
        .lock()
        .expect("host context")
        .as_ref()
        .expect("published host")
        .value
        .snapshot
        .clone();
    let runner = Arc::new(CountingRefusingRunner(AtomicUsize::new(0)));
    let request = AttachRequest {
        host_id: "wsl".to_owned(),
        host: WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            Arc::clone(&runner) as SharedCommandRunner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        ),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        target: AttachTarget::Herdr {
            executable: "/opt/herdr/bin/herdr".to_owned(),
            is_default: true,
            session_directory: "/tmp/herdr/default".to_owned(),
            socket_path: "/tmp/herdr/default/herdr.sock".to_owned(),
        },
        name: "default".to_owned(),
        inventory_generation: 1,
    };
    let retry = RetainedRetry {
        key: request.presentation_key(),
        request: request.clone(),
    };
    workspace
        .scene
        .retained_presentations
        .lock()
        .expect("retained presentations")
        .restarting
        .push(RetainedRestart {
            key: retry.key.clone(),
            selection: request.selection(),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm,
                generation: 1,
                fallback: None,
            },
            presentation_id: 7,
        });

    workspace
        .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
        .expect("running session may be stopped");
    let pending = {
        let mut lifecycle = workspace
            .scene
            .runtime
            .herdr_lifecycle
            .lock()
            .expect("lifecycle state");
        let pending = workspace
            .scene
            .pending_herdr_lifecycle
            .lock()
            .expect("pending lifecycle")
            .take()
            .expect("pending stop");
        assert!(lifecycle.start(&pending));
        pending
    };

    let suppressed = workspace.close_herdr_presentations(&pending);
    assert_eq!(suppressed.len(), 1);
    assert_eq!(
        suppressed[0].restarts.len(),
        1,
        "suppression revokes the restarting registration"
    );
    crate::scene::run_retained_retry(&workspace.scene, &retry);
    assert_eq!(
        runner.0.load(Ordering::Acquire),
        0,
        "a revoked registration executes no host command"
    );

    publish_herdr_lifecycle_uncertain(
        &workspace.scene.runtime,
        &pending,
        suppressed,
        "could not reconcile the stopped session",
    );
    let reconciliation_floor = workspace
        .scene
        .runtime
        .refresh_generation
        .load(Ordering::Acquire);
    let recovered = reconcile_herdr_lifecycle_fences(
        &workspace.scene.runtime,
        &snapshot,
        reconciliation_floor + 1,
        true,
    );
    assert_eq!(recovered.recoveries.len(), 1);
    assert_eq!(
        recovered.recoveries[0].restarts.len(),
        1,
        "the revoked registration survives the delayed-recovery hand-off"
    );

    Workspace::restore_delayed_herdr_presentations(&workspace.scene, recovered.recoveries);
    settle(
        "the restored registration's retry runs in the owner",
        || runner.0.load(Ordering::Acquire) > 0,
    );
}

#[test]
fn uncertain_lifecycle_stays_fenced_until_fresh_inventory_arrives() {
    let (workspace, _runtime) = herdr_workspace_fixture();
    let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
    workspace
        .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
        .expect("running session may be stopped");
    let pending = {
        let mut lifecycle = workspace
            .scene
            .runtime
            .herdr_lifecycle
            .lock()
            .expect("lifecycle state");
        let pending = workspace
            .scene
            .pending_herdr_lifecycle
            .lock()
            .expect("pending lifecycle")
            .take()
            .expect("pending stop");
        assert!(lifecycle.start(&pending));
        pending
    };

    publish_herdr_lifecycle_uncertain(
        &workspace.scene.runtime,
        &pending,
        vec![SuppressedHerdrPresentation {
            restarts: Vec::new(),
            scene_id: workspace.scene.id,
            active_selection: Some(running.clone()),
            retained: None,
            navigation_generation: workspace
                .scene
                .navigation_generation
                .load(Ordering::Acquire),
        }],
        "could not reconcile the stopped session",
    );

    let uncertain = workspace.snapshot();
    let host = &uncertain.hosts()[0];
    assert_eq!(
        host.herdr_sessions()[0].lifecycle_action(),
        Some(HerdrLifecycleAction::Stop)
    );
    assert!(host.herdr_diagnostic().is_some());

    let fresh = workspace
        .scene
        .runtime
        .host
        .lock()
        .expect("host context")
        .as_ref()
        .expect("published host")
        .value
        .snapshot
        .clone();
    let reconciliation_floor = workspace
        .scene
        .runtime
        .refresh_generation
        .load(Ordering::Acquire);
    assert_inconclusive_inventory_keeps_lifecycle_fenced(&workspace, &fresh, reconciliation_floor);
    let deferred = reconcile_herdr_lifecycle_fences(
        &workspace.scene.runtime,
        &fresh,
        reconciliation_floor + 3,
        false,
    );
    assert!(!deferred.changed);
    assert!(deferred.recoveries.is_empty());
    let mut reconciled_recovery = reconcile_herdr_lifecycle_fences(
        &workspace.scene.runtime,
        &fresh,
        reconciliation_floor + 4,
        true,
    );
    assert!(reconciled_recovery.changed);
    assert_eq!(reconciled_recovery.recoveries.len(), 1);
    assert_eq!(
        reconciled_recovery
            .recoveries
            .pop()
            .and_then(|recovery| recovery.active_selection),
        Some(running),
    );
    set_herdr_inventory(&workspace.scene.runtime, fresh.herdr());
    workspace
        .scene
        .runtime
        .revision
        .fetch_add(1, Ordering::Release);

    let reconciled = workspace.snapshot();
    let host = &reconciled.hosts()[0];
    assert_eq!(host.herdr_sessions()[0].lifecycle_action(), None);
    assert!(host.herdr_diagnostic().is_none());
}

#[test]
fn ordinary_refresh_cannot_reconcile_an_active_lifecycle_operation() {
    let (workspace, _runtime) = herdr_workspace_fixture();
    let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
    workspace
        .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
        .expect("running session may be stopped");
    {
        let mut lifecycle = workspace
            .scene
            .runtime
            .herdr_lifecycle
            .lock()
            .expect("lifecycle state");
        let pending = workspace
            .scene
            .pending_herdr_lifecycle
            .lock()
            .expect("pending lifecycle")
            .take()
            .expect("pending stop");
        assert!(lifecycle.start(&pending));
    }
    let snapshot = workspace
        .scene
        .runtime
        .host
        .lock()
        .expect("host context")
        .as_ref()
        .expect("published host")
        .value
        .snapshot
        .clone();

    assert!(
        !reconcile_herdr_lifecycle_fences(&workspace.scene.runtime, &snapshot, u64::MAX, true)
            .changed
    );
    assert_eq!(
        workspace.snapshot().hosts()[0].herdr_sessions()[0].lifecycle_action(),
        Some(HerdrLifecycleAction::Stop),
    );
}

#[test]
fn stop_preparation_removes_every_matching_retained_client() {
    let (workspace, _runtime) = herdr_workspace_fixture();
    let selection = SessionSelection::herdr("wsl", "Ubuntu", "default");
    let request = capture_attach_request(&workspace.scene, &selection)
        .expect("running Herdr session is attachable");
    let key = request.presentation_key();
    let attachment = |generation| ActiveAttachment {
        request: request.clone(),
        term: AttachTerm::Xterm256Color,
        generation,
        fallback: None,
    };
    let mut retained = RetainedPresentations::new();
    retained.insert(RetainedPresentation {
        key: key.clone(),
        selection: selection.clone(),
        attachment: attachment(1),
        worker: 1_u8,
        presentation_id: 1,
    });
    retained.entries.push(RetainedPresentation {
        key: key.clone(),
        selection,
        attachment: attachment(2),
        worker: 2_u8,
        presentation_id: 2,
    });

    let removed = retained.take_matching(|candidate| candidate == &key);

    assert_eq!(removed.len(), 2);
    assert!(!retained.contains(&key));
}

#[test]
fn fresh_inventory_supersedes_a_synthetic_lifecycle_response() {
    let (workspace, _runtime) = herdr_workspace_fixture();
    let running = SessionSelection::herdr("wsl", "Ubuntu", "default");
    workspace
        .request_herdr_lifecycle(&running, HerdrLifecycleAction::Stop)
        .expect("running session may be stopped");
    let pending = workspace
        .scene
        .pending_herdr_lifecycle
        .lock()
        .expect("lifecycle state")
        .clone()
        .expect("pending stop");
    let stopped = session::HerdrSessionRecord::new(
        "default",
        true,
        HerdrSessionState::Stopped,
        "/tmp/herdr/default",
        "/tmp/herdr/default/herdr.sock",
    );
    let before = workspace
        .scene
        .runtime
        .host
        .lock()
        .expect("host context")
        .as_ref()
        .expect("published host")
        .value
        .snapshot
        .clone();
    assert!(!herdr_lifecycle_is_reflected(&before, &pending));

    publish_herdr_lifecycle_response(&workspace.scene, &pending, stopped)
        .expect("authoritative response publishes");

    let snapshot = workspace.snapshot();
    let host = &snapshot.hosts()[0];
    assert_eq!(host.sessions()[0].name(), "work");
    assert_eq!(host.herdr_sessions()[0].state(), HerdrSessionState::Stopped);
    let published = workspace
        .scene
        .runtime
        .host
        .lock()
        .expect("host context")
        .as_ref()
        .expect("published host")
        .value
        .snapshot
        .clone();
    assert!(herdr_lifecycle_is_reflected(&published, &pending));

    let fresh_generation = reserve_constructive_inventory(&workspace.scene.runtime);
    merge_herdr_lifecycle_inventory(&workspace.scene, &pending, before.clone(), fresh_generation)
        .expect("fresh contradictory inventory publishes");
    assert!(!herdr_lifecycle_is_reflected(&before, &pending));
    assert_eq!(
        workspace.snapshot().hosts()[0].herdr_sessions()[0].state(),
        HerdrSessionState::Running,
    );
}

#[test]
fn restart_preserves_an_authoritative_name_outside_the_creation_subset() {
    let name = "review session";
    let (workspace, _runtime) =
        herdr_workspace_with_sessions(vec![session::HerdrSessionRecord::new(
            name,
            false,
            HerdrSessionState::Stopped,
            "/tmp/herdr/review session",
            "/tmp/herdr/review session/herdr.sock",
        )]);

    let request = capture_herdr_restart_request(
        &workspace.scene,
        &SessionSelection::herdr("wsl", "Ubuntu", name),
    )
    .expect("discovered session names remain restartable");

    assert_eq!(request.name.as_str(), name);
    assert!(matches!(
        request.precondition,
        HerdrLaunchPrecondition::Stopped(record) if record.name() == name
    ));
}

#[test]
fn restart_rejects_a_session_whose_default_role_changed() {
    let expected = session::HerdrSessionRecord::new(
        "review",
        false,
        HerdrSessionState::Stopped,
        "/tmp/herdr/review",
        "/tmp/herdr/review/herdr.sock",
    );
    let current = session::HerdrSessionRecord::new(
        "review",
        true,
        HerdrSessionState::Stopped,
        "/tmp/herdr/review",
        "/tmp/herdr/review/herdr.sock",
    );

    assert!(
        validate_herdr_launch_precondition(
            &HerdrLaunchPrecondition::Stopped(expected),
            Some(&current),
        )
        .is_err()
    );
}

#[test]
fn restart_result_rejects_a_same_named_replacement() {
    let expected = session::HerdrSessionRecord::new(
        "review",
        false,
        HerdrSessionState::Stopped,
        "/tmp/herdr/review",
        "/tmp/herdr/review/herdr.sock",
    );
    let replacement = session::HerdrSessionRecord::new(
        "review",
        false,
        HerdrSessionState::Running,
        "/tmp/herdr/replacement",
        "/tmp/herdr/replacement/herdr.sock",
    );

    assert!(!herdr_launch_result_matches(
        &HerdrLaunchPrecondition::Stopped(expected),
        "review",
        &replacement,
    ));
}

#[test]
fn herdr_startup_polling_accepts_a_session_after_early_misses() {
    let cancellation = CancellationToken::new();
    let mut probes = 0;

    let result = poll_session_startup(
        "Herdr",
        &cancellation,
        &[Duration::ZERO; 6],
        || -> Result<Option<&'static str>, WorkspaceError> {
            probes += 1;
            Ok((probes == 6).then_some("running"))
        },
    )
    .expect("polling succeeds");

    assert_eq!(result, Some("running"));
    assert_eq!(probes, 6);
}

#[test]
fn launched_remote_session_polling_outlives_navigation_intent() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let cancellation = CancellationToken::new();
    let launch_navigation = workspace.begin_navigation();
    let mut probes = 0;

    let result = poll_session_startup(
        "remote multiplexer",
        &cancellation,
        &[Duration::ZERO],
        || -> Result<Option<&'static str>, WorkspaceError> {
            probes += 1;
            if probes == 1 {
                workspace.begin_navigation();
                assert!(!workspace.navigation_intent_is_current(launch_navigation));
                Ok(None)
            } else {
                Ok(Some("published"))
            }
        },
    )
    .expect("connection-scoped polling survives navigation");

    assert_eq!(result, Some("published"));
    assert_eq!(probes, 2);
    assert!(!cancellation.is_cancelled());
}

#[test]
fn herdr_refresh_failure_preserves_cached_rows() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    set_herdr_inventory(
        &workspace.scene.runtime,
        &HerdrInventory::Available {
            executable: "/opt/herdr/bin/herdr".to_owned(),
            sessions: vec![session::HerdrSessionRecord::new(
                "review",
                false,
                HerdrSessionState::Running,
                "/tmp/herdr/review",
                "/tmp/herdr/review/herdr.sock",
            )],
        },
    );
    set_herdr_inventory(
        &workspace.scene.runtime,
        &HerdrInventory::Failed(
            WslExecutable::from_absolute("wsl.exe").expect_err("relative path is rejected"),
        ),
    );

    let snapshot = workspace.snapshot();
    let host = &snapshot.hosts()[0];
    assert!(host.herdr_available());
    assert_eq!(host.herdr_sessions()[0].name(), "review");
    assert_eq!(
        host.herdr_diagnostic().expect("scoped diagnostic").kind(),
        DiagnosticKind::MalformedOutput
    );
}

#[test]
fn zellij_refresh_failure_preserves_cached_rows() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    set_zellij_inventory(
        &workspace.scene.runtime,
        &ZellijInventory::Available {
            executable: "/opt/zellij/bin/zellij".to_owned(),
            sessions: vec![session::ZellijSessionRecord::discovered("review")],
        },
    );
    set_zellij_inventory(
        &workspace.scene.runtime,
        &ZellijInventory::Failed(
            WslExecutable::from_absolute("wsl.exe").expect_err("relative path is rejected"),
        ),
    );

    let snapshot = workspace.snapshot();
    let host = &snapshot.hosts()[0];
    assert!(host.zellij_available());
    assert_eq!(host.zellij_sessions()[0].name(), "review");
    assert_eq!(
        host.zellij_diagnostic().expect("scoped diagnostic").kind(),
        DiagnosticKind::MalformedOutput
    );
}

#[test]
fn host_refresh_keeps_cached_multiplexer_rows_visible() {
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application(TerminalAppearance::default(), Some(spec));
    {
        let mut hosts = workspace.scene.runtime.hosts.write().expect("hosts");
        let host = &mut hosts[0];
        host.connection = HostConnectionState::Ready;
        host.sessions = vec![SessionItem::new("tmux-work", 0)];
        host.herdr_available = true;
        host.herdr_sessions = vec![HerdrSessionItem::new(
            "herdr-work",
            false,
            HerdrSessionState::Running,
        )];
        host.zellij_available = true;
        host.zellij_sessions = vec![SessionItem::new("zellij-work", 0)];
    }

    begin_refresh(
        &workspace.scene,
        &CancellationToken::new(),
        RefreshPresentation::Connecting,
    );

    let snapshot = workspace.snapshot();
    assert!(matches!(snapshot.content(), WorkspaceContent::Shell));
    let host = &snapshot.hosts()[0];
    assert_eq!(host.connection(), HostConnectionState::Connecting);
    assert_eq!(host.sessions()[0].name(), "tmux-work");
    assert_eq!(host.herdr_sessions()[0].name(), "herdr-work");
    assert_eq!(host.zellij_sessions()[0].name(), "zellij-work");
}

#[test]
fn kwt_inventory_projects_worktrees_without_replacing_session_state() {
    let bundle =
        host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
    let config = WslConfig::with_distro("Ubuntu")
        .expect("valid config")
        .with_kwt_bundle(bundle);
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let workspace = Workspace::application(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
    );
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot",
        42,
        vec![session::DiscoveredSession::new(
            "project-main",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    );
    let runtime_host = WslHost::new(
        config,
        Arc::new(StdCommandRunner) as SharedCommandRunner,
        executable,
    );
    *workspace.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: runtime_host,
            snapshot: snapshot.clone(),
        },
        1,
    ));
    set_inventory_state(&workspace.scene.runtime, &ready_content(&snapshot));
    workspace
        .scene
        .runtime
        .kwt_refresh_generation
        .store(7, Ordering::Release);
    let inventory = KwtInventory::parse(
            br#"[{"repository":"project-id","name":"project","path":"/repos/project","last_touched":null,"registration_fingerprint":"project-fingerprint"}]"#,
            br#"[{"path":"/repos/project","branch":"main","commit_hash":"abc","is_main":true,"created_at":null,"generation":"g1","repository":"project-id","session_name":"project-main","tmux_socket_name":null}]"#,
            br#"[{"name":"scratch","path":"/work/scratch","session_name":"scratch","session_live":false}]"#,
        )
        .expect("valid KWT inventory");

    publish_kwt_inventory(
        &workspace.scene,
        7,
        snapshot.endpoint(),
        snapshot.runtime(),
        &inventory,
    );

    let projected = workspace.snapshot();
    assert!(matches!(projected.content(), WorkspaceContent::Shell));
    let host = &projected.hosts()[0];
    assert!(host.kwt_available());
    assert_eq!(host.projects()[0].name(), "project");
    assert_eq!(host.projects()[0].worktrees()[0].branch(), "main");
    assert!(host.projects()[0].worktrees()[0].session_available());
    assert_eq!(host.directory_workspaces()[0].name(), "scratch");
    assert!(!host.directory_workspaces()[0].session_available());

    set_inventory_state(
        &workspace.scene.runtime,
        &WorkspaceContent::Ready {
            endpoint: "Ubuntu".to_owned(),
            sessions: Vec::new(),
        },
    );
    let refreshed = workspace.snapshot();
    assert_eq!(refreshed.hosts()[0].projects().len(), 1);
    assert!(
        !refreshed.hosts()[0].projects()[0].worktrees()[0].session_available(),
        "the fast tmux refresh reconciles availability without rerunning KWT"
    );

    workspace
        .scene
        .runtime
        .kwt_mutation_in_flight
        .store(true, Ordering::Release);
    assert!(
        !start_kwt_refresh(&workspace.scene, true),
        "inventory reads cannot supersede a project mutation"
    );
    {
        let mut hosts = workspace.scene.runtime.hosts.write().expect("hosts");
        hosts[0].kwt_state = KwtState::Mutating;
    }
    publish_kwt_mutation_failure(&workspace.scene, 7, snapshot.endpoint(), snapshot.runtime());
    finish_kwt_project_mutation(
        &workspace.scene,
        Some((snapshot.endpoint(), snapshot.runtime())),
    );
    let failed = workspace.snapshot();
    assert_eq!(failed.hosts()[0].projects()[0].name(), "project");
    assert!(failed.hosts()[0].kwt_diagnostic().is_none());
    assert!(!failed.hosts()[0].kwt_mutating());
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one fixture verifies ordinary and protected KWT identity from the same inventory"
)]
fn worktree_open_uses_durable_kwt_identity_even_without_a_live_tmux_session() {
    let bundle =
        host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
    let config = WslConfig::with_distro("Ubuntu")
        .expect("valid config")
        .with_kwt_bundle(bundle);
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let workspace = Workspace::application(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
    );
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
    *workspace.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: WslHost::new(
                config,
                Arc::new(StdCommandRunner) as SharedCommandRunner,
                executable,
            ),
            snapshot: snapshot.clone(),
        },
        3,
    ));
    *workspace
        .scene
        .selected_host
        .write()
        .expect("selected host") = Some("wsl".to_owned());
    set_inventory_state(&workspace.scene.runtime, &ready_content(&snapshot));
    workspace
        .scene
        .runtime
        .kwt_refresh_generation
        .store(7, Ordering::Release);
    let inventory = KwtInventory::parse(
            br#"[{"repository":"project-id","name":"project","path":"/repos/project","last_touched":null,"registration_fingerprint":"project-fingerprint"}]"#,
            br#"[{"path":"/work/project/topic","branch":"topic","commit_hash":"abc","is_main":false,"created_at":null,"generation":"g7","repository":"project-id","session_name":"project-topic","tmux_socket_name":null},{"path":"/work/project/pr-17","branch":"pr-17","commit_hash":"def","is_main":false,"created_at":null,"generation":"g8","repository":"project-id","session_name":"project-pr-17","tmux_socket_name":"kwt-pr-a1b2"}]"#,
            b"[]",
        )
        .expect("valid KWT inventory");
    publish_kwt_inventory(
        &workspace.scene,
        7,
        snapshot.endpoint(),
        snapshot.runtime(),
        &inventory,
    );

    let request = capture_kwt_worktree_request(
        &workspace.scene,
        "wsl",
        "Ubuntu",
        "project-id",
        "/repos/project",
        "project-fingerprint",
        "/work/project/topic",
        Some("g7"),
        "project-topic",
        None,
    )
    .expect("KWT identity grants repair-or-open authority");
    assert!(matches!(request.target, AttachTarget::Worktree { .. }));
    assert_eq!(request.name, "project-topic");
    let protected = capture_kwt_worktree_request(
        &workspace.scene,
        "wsl",
        "Ubuntu",
        "project-id",
        "/repos/project",
        "project-fingerprint",
        "/work/project/pr-17",
        Some("g8"),
        "project-pr-17",
        Some("kwt-pr-a1b2"),
    )
    .expect("KWT identity grants protected attach authority");
    assert!(matches!(
        protected.target,
        AttachTarget::ProtectedWorktree { ref tmux_socket_name, .. }
            if tmux_socket_name == "kwt-pr-a1b2"
    ));
    let protected_selection = protected.selection();
    assert_eq!(protected_selection.tmux_socket_name(), Some("kwt-pr-a1b2"));
    assert_ne!(
        protected_selection,
        SessionSelection::new("wsl", "Ubuntu", "project-pr-17"),
        "a same-named default-socket session is a different presentation"
    );
    assert!(
        capture_kwt_worktree_request(
            &workspace.scene,
            "wsl",
            "Ubuntu",
            "project-id",
            "/repos/project",
            "project-fingerprint",
            "/work/project/pr-17",
            Some("g8"),
            "project-pr-17",
            Some("kwt-pr-replaced"),
        )
        .is_err(),
        "a stale protected-socket action cannot open the replacement server"
    );
    assert!(matches!(
        capture_kill_request(&workspace.scene, &protected_selection, 9)
            .expect("protected selection grants a fresh named-socket kill query"),
        KillCaptureRequest::Tmux { selection, .. }
            if selection.tmux_socket_name() == Some("kwt-pr-a1b2")
    ));
    assert!(
        capture_kwt_worktree_request(
            &workspace.scene,
            "wsl",
            "Ubuntu",
            "project-id",
            "/repos/project",
            "project-fingerprint",
            "/work/project/topic",
            Some("stale"),
            "project-topic",
            None,
        )
        .is_err()
    );
}

#[test]
fn confirmed_project_mutation_survives_failed_inventory_reconciliation() {
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let workspace = Workspace::application(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
    );
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
    *workspace.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: WslHost::new(
                config,
                Arc::new(StdCommandRunner) as SharedCommandRunner,
                executable,
            ),
            snapshot: snapshot.clone(),
        },
        1,
    ));
    workspace
        .scene
        .runtime
        .kwt_refresh_generation
        .store(7, Ordering::Release);
    let added = KwtInventory::parse(
            br#"[{"repository":"added-id","name":"added","path":"/repos/added","last_touched":null,"registration_fingerprint":"added-fingerprint"}]"#,
            b"[]",
            b"[]",
        )
        .expect("valid mutation project");
    let added = added.projects()[0].project();
    publish_kwt_project_mutation(
        &workspace.scene,
        7,
        snapshot.endpoint(),
        snapshot.runtime(),
        KwtProjectAction::Add,
        added,
    );
    publish_kwt_error(
        &workspace.scene,
        7,
        snapshot.endpoint(),
        snapshot.runtime(),
        HostDiagnostic::new(
            DiagnosticKind::Transport,
            "post-registration inventory failed",
        ),
    );
    let reconciled = workspace.snapshot();
    assert_eq!(reconciled.hosts()[0].projects()[0].name(), "added");
    assert!(reconciled.hosts()[0].kwt_diagnostic().is_some());

    publish_kwt_project_mutation(
        &workspace.scene,
        7,
        snapshot.endpoint(),
        snapshot.runtime(),
        KwtProjectAction::Remove,
        added,
    );
    let removed = workspace.snapshot();
    assert!(removed.hosts()[0].projects().is_empty());
}

#[test]
fn failed_kwt_inventory_keeps_constructive_add_separate_from_remove_authority() {
    let mut host = HostItem::wsl("Ubuntu", None, HostConnectionState::Ready, Vec::new(), None);
    host.kwt_state = KwtState::Unavailable;
    host.kwt_diagnostic = Some(HostDiagnostic::new(
        DiagnosticKind::Transport,
        "automatic inventory failed",
    ));

    assert!(host.can_add_kwt_project());
    assert!(!host.can_remove_kwt_project());
}

#[test]
fn stale_kwt_publication_cannot_replace_the_current_project_tree() {
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let workspace = Workspace::application(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
    );
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
    *workspace.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: WslHost::new(
                config,
                Arc::new(StdCommandRunner) as SharedCommandRunner,
                executable,
            ),
            snapshot: snapshot.clone(),
        },
        1,
    ));
    workspace
        .scene
        .runtime
        .kwt_refresh_generation
        .store(2, Ordering::Release);
    let inventory = KwtInventory::parse(
            br#"[{"repository":"project-id","name":"stale","path":"/repos/stale","last_touched":null,"registration_fingerprint":"stale-fingerprint"}]"#,
            b"[]",
            b"[]",
        )
        .expect("valid KWT inventory");

    publish_kwt_inventory(
        &workspace.scene,
        1,
        snapshot.endpoint(),
        snapshot.runtime(),
        &inventory,
    );

    assert!(workspace.snapshot().hosts()[0].projects().is_empty());
}

#[test]
fn background_cadence_refreshes_ready_hosts_and_reuses_the_admitted_host() {
    let runtime = Arc::new(ManualRefreshRuntime::default());
    let discovery = Arc::new(FixedDiscovery::new(HostSnapshot::test_fixture(
        "Ubuntu",
        "boot",
        42,
        vec![session::DiscoveredSession::new(
            "work",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    )));
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        discovery.clone(),
        runtime.clone(),
    );

    workspace.connect_enabled_hosts().expect("connect host");
    assert!(!workspace.refresh_if_ready().expect("connecting no-op"));
    runtime.run_next_work();
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Ready
    );
    runtime.run_next_deadline();

    workspace
        .start_inventory_cadence()
        .expect("start inventory cadence");
    workspace.set_inventory_polling_enabled(true);
    workspace
        .start_inventory_cadence()
        .expect("cadence start is idempotent");
    assert_eq!(runtime.deadline_delays(), vec![INVENTORY_REFRESH_INTERVAL]);
    let before_refresh = workspace.snapshot();
    runtime.run_next_deadline();
    let refreshing = workspace.snapshot();
    assert_eq!(
        refreshing.hosts()[0].connection(),
        HostConnectionState::Ready,
        "background refresh keeps the usable host and its actions visible"
    );
    assert_eq!(
        refreshing.revision(),
        before_refresh.revision(),
        "starting background work does not publish transient UI state"
    );
    assert!(
        capture_create_request(
            &workspace.scene,
            "wsl",
            "Ubuntu",
            SessionName::parse("new work").expect("valid name"),
        )
        .is_ok(),
        "an admitted host remains available for creation while its inventory refreshes"
    );
    assert!(
        capture_create_request(
            &workspace.scene,
            "wsl",
            "Debian",
            SessionName::parse("new work").expect("valid name"),
        )
        .is_err(),
        "creation never follows a changed default distro implicitly"
    );
    runtime.run_next_work();

    assert_eq!(discovery.reused_hosts.load(Ordering::Acquire), 1);
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Ready
    );
}

#[test]
fn inventory_cadence_is_a_no_op_without_an_enabled_host() {
    let runtime = Arc::new(ManualRefreshRuntime::default());
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        None,
        Arc::new(SystemWslDiscovery::new()),
        runtime.clone(),
    );

    workspace
        .start_inventory_cadence()
        .expect("missing WSL host is not a scheduling error");

    assert!(runtime.deadline_delays().is_empty());
    assert!(
        !workspace
            .scene
            .runtime
            .inventory_cadence_started
            .load(Ordering::Acquire)
    );
}

#[test]
fn kwt_inventory_uses_a_distinct_slower_cadence() {
    let runtime = Arc::new(ManualRefreshRuntime::default());
    let bundle =
        host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
    let config = WslConfig::with_distro("Ubuntu")
        .expect("valid config")
        .with_kwt_bundle(bundle);
    let spec = WslHostSpec::available(
        config,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        Arc::new(SystemWslDiscovery::new()),
        runtime.clone(),
    );

    workspace
        .start_inventory_cadence()
        .expect("start both inventory cadences");
    workspace
        .start_inventory_cadence()
        .expect("cadence start remains idempotent");

    assert_eq!(
        runtime.deadline_delays(),
        vec![INVENTORY_REFRESH_INTERVAL, KWT_REFRESH_INTERVAL]
    );
}

#[test]
fn background_kwt_refresh_requires_the_matching_host_to_be_ready() {
    let bundle =
        host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
    let config = WslConfig::with_distro("Ubuntu")
        .expect("valid config")
        .with_kwt_bundle(bundle);
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let workspace = Workspace::application(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
    );
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
    *workspace.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: WslHost::new(
                config,
                Arc::new(StdCommandRunner) as SharedCommandRunner,
                executable,
            ),
            snapshot,
        },
        1,
    ));

    for state in [
        HostConnectionState::Disconnected,
        HostConnectionState::Unavailable,
    ] {
        workspace.scene.runtime.hosts.write().expect("hosts")[0].connection = state;
        assert!(
            reserve_kwt_refresh(&workspace.scene, false).is_none(),
            "background KWT work must not use retained host authority while {state:?}"
        );
    }

    workspace.scene.runtime.hosts.write().expect("hosts")[0].connection =
        HostConnectionState::Ready;
    let refresh = reserve_kwt_refresh(&workspace.scene, false)
        .expect("ready matching host permits background KWT refresh");
    refresh.cancellation.cancel();
}

#[test]
fn failed_mutation_spawn_starts_deferred_kwt_refresh_for_replaced_runtime() {
    let runtime = Arc::new(ManualRefreshRuntime::default());
    let bundle =
        host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
    let config = WslConfig::with_distro("Ubuntu")
        .expect("valid config")
        .with_kwt_bundle(bundle.clone());
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
        Arc::new(SystemWslDiscovery::new()),
        runtime.clone(),
    );
    let old_snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-old", 42, Vec::new());
    *workspace.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: WslHost::new(
                config,
                Arc::new(StdCommandRunner) as SharedCommandRunner,
                executable.clone(),
            ),
            snapshot: old_snapshot.clone(),
        },
        1,
    ));
    set_inventory_state(&workspace.scene.runtime, &ready_content(&old_snapshot));
    workspace.scene.runtime.hosts.write().expect("hosts")[0].kwt_state = KwtState::Ready;

    let replacement_scene = Arc::clone(&workspace.scene);
    runtime.fail_next_work(move || {
        let replacement = HostSnapshot::test_fixture("Debian", "boot-new", 84, Vec::new());
        let replacement_config = WslConfig::with_distro("Debian")
            .expect("valid replacement config")
            .with_kwt_bundle(bundle);
        *replacement_scene
            .runtime
            .host
            .lock()
            .expect("published host") = Some(Published::new(
            HostContext {
                host: WslHost::new(
                    replacement_config,
                    Arc::new(StdCommandRunner) as SharedCommandRunner,
                    executable,
                ),
                snapshot: replacement.clone(),
            },
            2,
        ));
        set_inventory_state(&replacement_scene.runtime, &ready_content(&replacement));
    });

    let error = workspace
        .add_kwt_project("wsl", "Ubuntu", "/repos/project")
        .expect_err("scripted mutation spawn fails");
    assert!(error.to_string().contains("scripted work spawn failure"));
    assert!(
        !workspace
            .scene
            .runtime
            .kwt_mutation_in_flight
            .load(Ordering::Acquire)
    );
    let snapshot = workspace.snapshot();
    assert_eq!(snapshot.hosts()[0].endpoint(), "Debian");
    assert!(snapshot.hosts()[0].kwt_refreshing());
    assert_eq!(
        runtime.work.lock().expect("work queue").len(),
        1,
        "settlement schedules the initial KWT refresh for the replacement runtime"
    );
}

#[test]
fn inactive_inventory_cadence_does_not_start_host_work() {
    let runtime = Arc::new(ManualRefreshRuntime::default());
    let discovery = Arc::new(FixedDiscovery::new(HostSnapshot::test_fixture(
        "Ubuntu",
        "boot",
        42,
        Vec::new(),
    )));
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        discovery,
        runtime.clone(),
    );

    workspace
        .start_inventory_cadence()
        .expect("start inventory cadence");
    runtime.run_next_deadline();

    assert!(runtime.work.lock().expect("work queue").is_empty());
    assert_eq!(runtime.deadline_delays(), vec![INVENTORY_REFRESH_INTERVAL]);
}

#[test]
fn inventory_cadence_yields_to_create_and_lifecycle_operations() {
    let runtime = Arc::new(ManualRefreshRuntime::default());
    let discovery = Arc::new(FixedDiscovery::new(HostSnapshot::test_fixture(
        "Ubuntu",
        "boot",
        42,
        Vec::new(),
    )));
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        discovery,
        runtime.clone(),
    );
    workspace.connect_enabled_hosts().expect("connect host");
    runtime.run_next_work();
    runtime.run_next_deadline();
    workspace.set_inventory_polling_enabled(true);
    workspace
        .start_inventory_cadence()
        .expect("start inventory cadence");
    let generation = workspace
        .scene
        .runtime
        .refresh_generation
        .load(Ordering::Acquire);

    {
        let _create_operation = workspace
            .scene
            .runtime
            .session_operations
            .lock()
            .expect("hold tmux creation lane");
        runtime.run_next_deadline();
        assert!(runtime.work.lock().expect("work queue").is_empty());
        assert_eq!(
            workspace
                .scene
                .runtime
                .refresh_generation
                .load(Ordering::Acquire),
            generation,
            "cadence cannot supersede tmux creation publication"
        );
    }

    {
        let _lifecycle_operation = workspace
            .scene
            .runtime
            .session_operations
            .lock()
            .expect("hold Herdr lifecycle lane");
        runtime.run_next_deadline();
        assert!(runtime.work.lock().expect("work queue").is_empty());
        assert_eq!(
            workspace
                .scene
                .runtime
                .refresh_generation
                .load(Ordering::Acquire),
            generation,
            "cadence cannot supersede Herdr lifecycle publication"
        );
    }

    runtime.run_next_deadline();
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Ready,
        "cadence resumes without demoting the usable host"
    );
    assert_eq!(
        workspace
            .scene
            .runtime
            .refresh_generation
            .load(Ordering::Acquire),
        generation + 1
    );
}

#[test]
fn cancelling_refresh_invalidates_work_and_restores_disconnected_host() {
    let runtime = Arc::new(ManualRefreshRuntime::default());
    let discovery = Arc::new(FixedDiscovery::new(HostSnapshot::test_fixture(
        "Ubuntu",
        "boot",
        42,
        vec![session::DiscoveredSession::new(
            "work",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    )));
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        discovery,
        runtime.clone(),
    );

    workspace.connect_enabled_hosts().expect("start refresh");
    let active_generation = workspace
        .scene
        .runtime
        .refresh_generation
        .load(Ordering::Acquire);
    assert!(workspace.cancel_refresh());
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Disconnected
    );
    assert!(
        workspace
            .scene
            .runtime
            .refresh_generation
            .load(Ordering::Acquire)
            > active_generation,
        "cancellation must invalidate late publication"
    );
    assert!(
        !workspace.cancel_refresh(),
        "disconnected refresh is inactive"
    );

    runtime.run_next_work();
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Disconnected,
        "cancelled discovery cannot publish"
    );
    runtime.run_next_deadline();
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Disconnected,
        "cancelled deadline cannot publish"
    );
}

#[test]
fn legacy_inventory_publication_still_updates_top_level_content() {
    let workspace = Workspace::preview(WorkspaceSnapshot {
        revision: 0,
        appearance: Appearance::default(),
        content: WorkspaceContent::Loading,
        hosts: vec![HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Connecting,
            Vec::new(),
            None,
        )],
        selected_host: Some("wsl".to_owned()),
        notice: None,
        active_selection: None,
        retained_selections: Vec::new(),
    });

    set_inventory_state(
        &workspace.scene.runtime,
        &WorkspaceContent::Ready {
            endpoint: "Ubuntu".to_owned(),
            sessions: vec![SessionItem::new("work", 0)],
        },
    );

    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Ready { sessions, .. }
            if sessions.len() == 1 && sessions[0].name() == "work"
    ));

    set_wsl_host_unavailable(
        &workspace.scene.runtime,
        DiagnosticKind::Timeout,
        "legacy refresh timed out".to_owned(),
    );
    let snapshot = workspace.snapshot();
    assert!(matches!(
        snapshot.content(),
        WorkspaceContent::Error { message } if message == "legacy refresh timed out"
    ));
    assert_eq!(
        snapshot.hosts()[0]
            .diagnostic()
            .expect("classified host diagnostic")
            .kind(),
        DiagnosticKind::Timeout
    );
}

#[test]
fn only_the_current_refresh_deadline_can_publish_timeout() {
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application(TerminalAppearance::default(), Some(spec));
    let stale = CancellationToken::new();
    let stale_generation = begin_refresh(&workspace.scene, &stale, RefreshPresentation::Connecting);
    let current = CancellationToken::new();
    let current_generation =
        begin_refresh(&workspace.scene, &current, RefreshPresentation::Connecting);

    assert!(!expire_refresh(&workspace.scene, stale_generation, &stale));
    assert!(expire_refresh(
        &workspace.scene,
        current_generation,
        &current
    ));
    assert!(current.is_cancelled());
    let snapshot = workspace.snapshot();
    assert_eq!(
        snapshot.hosts()[0].connection(),
        HostConnectionState::Unavailable
    );
    assert_eq!(
        snapshot.hosts()[0]
            .diagnostic()
            .expect("timeout diagnostic")
            .kind(),
        DiagnosticKind::Timeout
    );
}

#[test]
fn cancelled_remote_connection_cannot_publish_a_late_failure() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Connecting,
            Vec::new(),
            None,
        )],
    ));
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let cancellation = CancellationToken::new();
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            "ssh:studio".to_owned(),
            RemoteEntry {
                config,
                native_host: None,
                context: None,
                cancellation: Some(cancellation.clone()),
                constructive_cancellation: None,
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );

    assert!(workspace.cancel_host_connection("ssh:studio"));
    assert!(cancellation.is_cancelled());
    publish_remote_connection(
        &workspace.scene,
        "ssh:studio",
        7,
        Err(host::RemoteTmuxError::transport("late transport failure")),
    );

    let snapshot = workspace.snapshot();
    assert_eq!(
        snapshot.hosts()[0].connection(),
        HostConnectionState::Disconnected
    );
    assert!(snapshot.hosts()[0].diagnostic().is_none());
}

#[test]
fn remote_cancellation_waits_for_inventory_publication() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Connecting,
            Vec::new(),
            None,
        )],
    ));
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let cancellation = CancellationToken::new();
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            "ssh:studio".to_owned(),
            RemoteEntry {
                config,
                native_host: None,
                context: None,
                cancellation: Some(cancellation.clone()),
                constructive_cancellation: None,
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );

    let publication = workspace
        .scene
        .runtime
        .remote_publication
        .lock()
        .expect("hold inventory publication");
    let (completed_tx, completed_rx) = mpsc::sync_channel(1);
    // The cancelling thread reports whether the publication had released
    // when it completed; the publication mutex makes a true report
    // unreachable while the guard is held, so a cancellation that crossed
    // the in-progress publication fails deterministically.
    let publication_released = Arc::new(AtomicBool::new(false));
    let task_released = Arc::clone(&publication_released);
    let task_workspace = workspace.clone();
    thread::scope(|scope| {
        let cancellation_task = scope.spawn(move || {
            let cancelled = task_workspace.cancel_host_connection("ssh:studio");
            completed_tx
                .send((cancelled, task_released.load(Ordering::Acquire)))
                .expect("report cancellation");
        });

        set_remote_host_state(
            &workspace.scene.runtime,
            "ssh:studio",
            HostConnectionState::Ready,
            None,
            None,
        );
        publication_released.store(true, Ordering::Release);
        drop(publication);

        let (cancelled, after_release) = completed_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("cancellation completes after publication");
        assert!(cancelled);
        assert!(
            after_release,
            "cancellation cannot cross an in-progress inventory publication"
        );
        cancellation_task.join().expect("cancellation task");
    });

    assert!(cancellation.is_cancelled());
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Disconnected,
        "the newer cancellation transition wins over the completed publication"
    );
}

#[test]
fn stale_lease_exit_cannot_cancel_its_replacement_connection() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Connecting,
            Vec::new(),
            None,
        )],
    ));
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "",
        None,
    )
    .expect("valid remote host");
    let host = remote_host_fixture(&config);
    let stale = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        7,
        Vec::new(),
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );
    let replacement = CancellationToken::new();
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            "ssh:studio".to_owned(),
            RemoteEntry {
                config,
                native_host: Some(host.clone()),
                context: Some(RemoteHostContext {
                    generation: 7,
                    host,
                    snapshot: stale,
                }),
                cancellation: Some(replacement.clone()),
                constructive_cancellation: None,
                attachment_attempts: Vec::new(),
                generation: 8,
            },
        );

    let _backlog = pump_once(&workspace.scene.runtime);

    let entries = workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts");
    let entry = entries.get("ssh:studio").expect("remote entry");
    assert_eq!(entry.generation, 8);
    assert!(!replacement.is_cancelled());
    assert!(entry.context.is_some());
    drop(entries);
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Connecting
    );
}

#[test]
fn newer_navigation_cancels_a_queued_remote_attachment() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "",
        None,
    )
    .expect("valid remote host");
    let cancellation = CancellationToken::new();
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            "ssh:studio".to_owned(),
            RemoteEntry {
                config,
                native_host: None,
                context: None,
                cancellation: None,
                constructive_cancellation: None,
                attachment_attempts: vec![RemoteAttachmentAttempt {
                    scene: workspace.scene.id,
                    navigation_generation: 7,
                    cancellation: cancellation.clone(),
                }],
                generation: 1,
            },
        );

    workspace.begin_navigation();

    assert!(cancellation.is_cancelled());
    assert!(
        workspace
            .scene
            .runtime
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .get("ssh:studio")
            .expect("remote entry")
            .attachment_attempts
            .is_empty()
    );
}

#[test]
fn navigation_in_one_scene_leaves_other_scenes_remote_attempts_in_flight() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let b = a.open_scene();
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "",
        None,
    )
    .expect("valid remote host");
    let a_cancellation = CancellationToken::new();
    let b_cancellation = CancellationToken::new();
    a.scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: None,
                context: None,
                cancellation: None,
                constructive_cancellation: None,
                attachment_attempts: vec![
                    RemoteAttachmentAttempt {
                        scene: a.scene.id,
                        navigation_generation: 7,
                        cancellation: a_cancellation.clone(),
                    },
                    RemoteAttachmentAttempt {
                        scene: b.scene.id,
                        navigation_generation: 8,
                        cancellation: b_cancellation.clone(),
                    },
                ],
                generation: 1,
            },
        );

    // Scene B's navigation cancels only scene B's attempt.
    b.begin_navigation();
    assert!(
        !a_cancellation.is_cancelled(),
        "scene B's navigation leaves scene A's attempt in flight"
    );
    assert!(b_cancellation.is_cancelled());
    {
        let entries = a.scene.runtime.remote_hosts.lock().expect("remote hosts");
        let attempts = &entries
            .get("ssh:studio")
            .expect("remote entry")
            .attachment_attempts;
        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0].navigation_generation, 7);
    }

    // The initiating scene's own navigation still cancels its attempt.
    a.begin_navigation();
    assert!(a_cancellation.is_cancelled());
    assert!(
        a.scene
            .runtime
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .get("ssh:studio")
            .expect("remote entry")
            .attachment_attempts
            .is_empty()
    );
}

#[test]
fn concurrent_scene_attachment_attempts_coexist_on_one_host() {
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let host = remote_host_fixture(&config);
    let snapshot = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        7,
        Vec::new(),
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );
    let a = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let b = a.open_scene();
    a.scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: Some(host.clone()),
                context: Some(RemoteHostContext {
                    generation: 7,
                    host,
                    snapshot: snapshot.clone(),
                }),
                cancellation: None,
                constructive_cancellation: None,
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );
    let a_first = CancellationToken::new();
    register_remote_attachment(
        &a.scene.runtime,
        a.scene.id,
        "ssh:studio",
        7,
        &snapshot,
        11,
        &a_first,
    )
    .expect("scene A registers its attempt");

    // Scene B attaching to the same host does not supersede scene A.
    let b_attempt = CancellationToken::new();
    register_remote_attachment(
        &a.scene.runtime,
        b.scene.id,
        "ssh:studio",
        7,
        &snapshot,
        12,
        &b_attempt,
    )
    .expect("scene B registers alongside scene A");
    assert!(
        !a_first.is_cancelled(),
        "scene B's attempt does not cancel scene A's in-flight attempt"
    );

    // Scene A's retry supersedes only its own previous attempt.
    let a_second = CancellationToken::new();
    register_remote_attachment(
        &a.scene.runtime,
        a.scene.id,
        "ssh:studio",
        7,
        &snapshot,
        13,
        &a_second,
    )
    .expect("scene A supersedes its own attempt");
    assert!(a_first.is_cancelled());
    assert!(
        !b_attempt.is_cancelled(),
        "scene A's retry leaves scene B's attempt in flight"
    );

    // A finished attempt clears only its own registration.
    clear_remote_attachment_registration(&a.scene.runtime, "ssh:studio", 13);
    let entries = a.scene.runtime.remote_hosts.lock().expect("remote hosts");
    let attempts = &entries
        .get("ssh:studio")
        .expect("remote entry")
        .attachment_attempts;
    assert_eq!(attempts.len(), 1);
    assert_eq!(attempts[0].navigation_generation, 12);
}

#[test]
fn navigation_in_another_scene_leaves_remote_construction_active() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let b = a.open_scene();
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "",
        None,
    )
    .expect("valid remote host");
    let cancellation = CancellationToken::new();
    a.scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: None,
                context: None,
                cancellation: None,
                constructive_cancellation: Some(RemoteConstructiveState::Active {
                    scene: a.scene.id,
                    navigation_generation: 1,
                    cancellation: cancellation.clone(),
                    launched: Arc::new(AtomicBool::new(false)),
                    target: remote_zellij_target("review"),
                }),
                attachment_attempts: Vec::new(),
                generation: 1,
            },
        );

    // Two navigations in scene B mint generations past the construction's,
    // yet neither cancels scene A's un-launched construction.
    b.begin_navigation();
    b.begin_navigation();
    assert!(
        !cancellation.is_cancelled(),
        "another scene's navigation leaves the construction active"
    );

    // The initiating scene's newer navigation still cancels it.
    a.begin_navigation();
    assert!(
        cancellation.is_cancelled(),
        "the initiating scene's newer navigation supersedes its construction"
    );
}

#[test]
fn superseded_remote_attachment_cannot_cross_the_launch_fence() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "",
        None,
    )
    .expect("valid remote host");
    let cancellation = CancellationToken::new();
    workspace
        .scene
        .navigation_generation
        .store(7, Ordering::Release);
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            "ssh:studio".to_owned(),
            RemoteEntry {
                config,
                native_host: None,
                context: None,
                cancellation: None,
                constructive_cancellation: None,
                attachment_attempts: vec![RemoteAttachmentAttempt {
                    scene: workspace.scene.id,
                    navigation_generation: 7,
                    cancellation: cancellation.clone(),
                }],
                generation: 1,
            },
        );
    workspace.begin_navigation();
    let launched = AtomicBool::new(false);

    let result = with_current_remote_attachment_launch(
        &workspace.scene,
        "ssh:studio",
        7,
        &cancellation,
        || {
            launched.store(true, Ordering::Release);
            Ok(())
        },
    );

    assert!(result.is_err());
    assert!(!launched.load(Ordering::Acquire));
}

#[test]
fn connecting_remote_host_rejects_fresh_session_actions() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Connecting,
            Vec::new(),
            None,
        )],
    ));
    let selection = SessionSelection::new("ssh:studio", "studio.example", "build");

    let error = require_host_session_actions(&workspace.scene.runtime, &selection)
        .expect_err("connecting hosts cannot authorize fresh actions");

    assert!(error.to_string().contains("ready"));
}

#[test]
fn connecting_wsl_host_preserves_cached_session_actions() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Connecting,
            vec![SessionItem::new("build", 0)],
            None,
        )],
    ));
    let selection = SessionSelection::new("wsl", "Ubuntu", "build");

    require_host_session_actions(&workspace.scene.runtime, &selection)
        .expect("WSL cached inventory remains actionable during refresh");
}

#[test]
fn refresh_after_remote_launch_transfers_inventory_reconciliation() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "",
        None,
    )
    .expect("valid remote host");
    let cancellation = CancellationToken::new();
    let target = remote_herdr_target("agents");
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: None,
                context: None,
                cancellation: None,
                constructive_cancellation: Some(RemoteConstructiveState::Active {
                    scene: workspace.scene.id,
                    navigation_generation: 6,
                    cancellation: cancellation.clone(),
                    launched: Arc::new(AtomicBool::new(true)),
                    target: target.clone(),
                }),
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );

    {
        let mut entries = workspace
            .scene
            .runtime
            .remote_hosts
            .lock()
            .expect("remote hosts");
        cancel_remote_constructive(entries.get_mut("ssh:studio").expect("remote entry"));
    }

    assert!(cancellation.is_cancelled());
    assert!(!remote_constructive_is_current(
        &workspace.scene.runtime,
        "ssh:studio",
        &cancellation
    ));
    let pending = pending_remote_constructive_target(&workspace.scene.runtime, "ssh:studio");
    assert_eq!(pending, Some(target.clone()));
    drop(RemoteConstructiveReset {
        scene: &workspace.scene,
        host_id: "ssh:studio",
        navigation_generation: 6,
    });
    assert_eq!(
        pending_remote_constructive_target(&workspace.scene.runtime, "ssh:studio"),
        Some(target)
    );
}

#[test]
fn navigation_cancels_only_prelaunch_remote_construction() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "",
        None,
    )
    .expect("valid remote host");
    let cancellation = CancellationToken::new();
    let launched = Arc::new(AtomicBool::new(false));
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: None,
                context: None,
                cancellation: None,
                constructive_cancellation: Some(RemoteConstructiveState::Active {
                    scene: workspace.scene.id,
                    navigation_generation: 7,
                    cancellation: cancellation.clone(),
                    launched: Arc::clone(&launched),
                    target: remote_zellij_target("review"),
                }),
                attachment_attempts: Vec::new(),
                generation: 1,
            },
        );

    cancel_superseded_remote_constructive_navigation(
        &workspace.scene.runtime,
        workspace.scene.id,
        8,
    );
    assert!(cancellation.is_cancelled());

    let post_launch_cancellation = CancellationToken::new();
    launched.store(true, Ordering::Release);
    if let Some(entry) = workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .get_mut("ssh:studio")
    {
        entry.constructive_cancellation = Some(RemoteConstructiveState::Active {
            scene: workspace.scene.id,
            navigation_generation: 7,
            cancellation: post_launch_cancellation.clone(),
            launched,
            target: remote_zellij_target("review"),
        });
    }

    cancel_superseded_remote_constructive_navigation(
        &workspace.scene.runtime,
        workspace.scene.id,
        8,
    );
    assert!(
        !post_launch_cancellation.is_cancelled(),
        "post-launch polling must survive navigation"
    );
}

#[test]
fn cancelled_remote_construction_stops_waiting_for_the_operation_lane() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let occupied = workspace
        .scene
        .runtime
        .session_operations
        .lock()
        .expect("occupy session operation lane");
    let cancellation = CancellationToken::new();

    thread::scope(|scope| {
        let (settled_tx, settled_rx) = mpsc::sync_channel(1);
        let scene = &workspace.scene;
        let waiter_cancellation = cancellation.clone();
        scope.spawn(move || {
            let operation = lock_session_operations(scene, &waiter_cancellation);
            settled_tx
                .send(operation.is_none())
                .expect("report cancelled wait");
        });
        cancellation.cancel();
        let settled = settled_rx.recv_timeout(Duration::from_secs(1));
        // Release the lane before asserting: a waiter that ignored its
        // cancellation must fail this test, not hang the scope join
        // spinning on the still-held mutex.
        drop(occupied);
        assert!(settled.expect("cancelled waiter settles promptly"));
    });
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "the runtime/scene split lengthens shared-state paths without adding logic"
)]
fn concurrent_remote_inventory_publication_settles_pending_reconciliation() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let host = remote_host_fixture(&config);
    let initial = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        7,
        Vec::new(),
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );
    let target = remote_herdr_target("agents");
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: Some(host.clone()),
                context: Some(RemoteHostContext {
                    generation: 7,
                    host: host.clone(),
                    snapshot: initial.clone(),
                }),
                cancellation: None,
                constructive_cancellation: Some(RemoteConstructiveState::PendingReconciliation(
                    target.clone(),
                )),
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );

    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    thread::scope(|scope| {
        let scene = &workspace.scene;
        let reconciliation_initial = initial.clone();
        let reconciliation_target = target.clone();
        let reconciliation = scope.spawn(move || {
            reconcile_remote_constructive_with_backoff(
                scene,
                "ssh:studio",
                7,
                reconciliation_initial,
                &reconciliation_target,
                &[Duration::ZERO, Duration::ZERO],
                |_snapshot, _cancellation| {
                    entered_tx.send(()).expect("announce stale probe");
                    release_rx
                        .recv_timeout(Duration::from_secs(10))
                        .expect("release stale probe");
                    Err::<RemoteSessionInventory, ()>(())
                },
            );
        });
        entered_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("reconciliation entered remote discovery");
        publish_remote_inventory(
            &workspace.scene,
            "ssh:studio",
            7,
            &initial,
            &CancellationToken::new(),
            RemoteSessionInventory::test_fixture(
                Some("/usr/bin/tmux".to_owned()),
                Vec::new(),
                HerdrInventory::Available {
                    executable: "/usr/bin/herdr".to_owned(),
                    sessions: vec![session::HerdrSessionRecord::new(
                        "agents",
                        false,
                        HerdrSessionState::Running,
                        "/tmp/herdr/agents",
                        "/tmp/herdr/agents/herdr.sock",
                    )],
                },
                ZellijInventory::Unavailable,
            ),
        )
        .expect("concurrent inventory publication wins");
        release_tx
            .send(())
            .expect("release stale reconciliation probe");
        reconciliation.join().expect("reconciliation completes");
    });

    assert_eq!(
        pending_remote_constructive_target(&workspace.scene.runtime, "ssh:studio"),
        None,
        "the authoritative concurrent snapshot settles the pending launch"
    );
}

#[test]
fn stale_remote_inventory_cannot_overwrite_the_published_generation() {
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let host = remote_host_fixture(&config);
    let identity = session::SessionIdentity::new(42, "$1", 100);
    let initial = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        7,
        vec![session::DiscoveredSession::new(
            "initial",
            identity.clone(),
            0,
        )],
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            vec![SessionItem::new("initial", 0)],
            None,
        )],
    ));
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: Some(host.clone()),
                context: Some(RemoteHostContext {
                    generation: 7,
                    host,
                    snapshot: initial.clone(),
                }),
                cancellation: None,
                constructive_cancellation: None,
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );
    let cancellation = CancellationToken::new();
    let winner = publish_remote_inventory(
        &workspace.scene,
        "ssh:studio",
        7,
        &initial,
        &cancellation,
        RemoteSessionInventory::test_fixture(
            Some("/usr/bin/tmux".to_owned()),
            vec![session::DiscoveredSession::new(
                "winner",
                identity.clone(),
                0,
            )],
            HerdrInventory::Unavailable,
            ZellijInventory::Unavailable,
        ),
    )
    .expect("first publication wins");

    let stale = publish_remote_inventory(
        &workspace.scene,
        "ssh:studio",
        7,
        &initial,
        &cancellation,
        RemoteSessionInventory::test_fixture(
            Some("/usr/bin/tmux".to_owned()),
            vec![session::DiscoveredSession::new("stale", identity, 0)],
            HerdrInventory::Unavailable,
            ZellijInventory::Unavailable,
        ),
    );

    assert!(stale.is_err());
    assert_eq!(winner.inventory_generation(), 1);
    assert_eq!(
        workspace.snapshot().hosts()[0].sessions()[0].name(),
        "winner"
    );
}

#[test]
fn display_only_ssh_host_edits_preserve_runtime_and_selection() {
    let config = RemoteTmuxConfig::new(
        "ssh:deploy@studio.example:22",
        "Studio",
        SshTarget::new("studio.example", Some("deploy".to_owned()), Some(22))
            .expect("valid target"),
        "",
        None,
    )
    .expect("valid remote host");
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            config.id(),
            config.name(),
            config.endpoint(),
            HostConnectionState::Ready,
            vec![SessionItem::new("work", 0)],
            None,
        )],
    ));
    let cancellation = CancellationToken::new();
    let constructive_cancellation = CancellationToken::new();
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config: config.clone(),
                native_host: None,
                context: None,
                cancellation: Some(cancellation.clone()),
                constructive_cancellation: Some(RemoteConstructiveState::Active {
                    scene: workspace.scene.id,
                    navigation_generation: 6,
                    cancellation: constructive_cancellation.clone(),
                    launched: Arc::new(AtomicBool::new(false)),
                    target: remote_zellij_target("review"),
                }),
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );
    let edited = SshHostSettings::new(
        "Build Mac",
        "studio.example",
        Some("deploy".to_owned()),
        Some(22),
        "",
        None,
    )
    .expect("valid settings");

    let navigation = lock_live_navigation(&workspace.scene).expect("scene is live");
    workspace
        .publish_saved_ssh_host(&navigation, Some(config.id()), &edited)
        .expect("publish display edit");
    drop(navigation);

    {
        let entries = workspace
            .scene
            .runtime
            .remote_hosts
            .lock()
            .expect("remote hosts");
        let entry = entries.get(config.id()).expect("preserved runtime");
        assert_eq!(entry.generation, 7);
    }
    assert!(!cancellation.is_cancelled());
    assert!(!constructive_cancellation.is_cancelled());
    let snapshot = workspace.snapshot();
    assert_eq!(snapshot.selected_host(), Some(config.id()));
    assert_eq!(snapshot.hosts()[0].name(), "Build Mac");
    assert_eq!(snapshot.hosts()[0].connection(), HostConnectionState::Ready);
    assert_eq!(snapshot.hosts()[0].sessions()[0].name(), "work");
}

#[test]
fn connection_changing_ssh_host_edits_disconnect_and_move_selection() {
    let config = RemoteTmuxConfig::new(
        "ssh:deploy@old.example:22",
        "Studio",
        SshTarget::new("old.example", Some("deploy".to_owned()), Some(22)).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            config.id(),
            config.name(),
            config.endpoint(),
            HostConnectionState::Connecting,
            Vec::new(),
            None,
        )],
    ));
    let cancellation = CancellationToken::new();
    let constructive_cancellation = CancellationToken::new();
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config: config.clone(),
                native_host: None,
                context: None,
                cancellation: Some(cancellation.clone()),
                constructive_cancellation: Some(RemoteConstructiveState::Active {
                    scene: workspace.scene.id,
                    navigation_generation: 6,
                    cancellation: constructive_cancellation.clone(),
                    launched: Arc::new(AtomicBool::new(false)),
                    target: remote_zellij_target("review"),
                }),
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );
    let edited = SshHostSettings::new(
        "Studio",
        "new.example",
        Some("deploy".to_owned()),
        Some(22),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid settings");
    let edited_id = edited.id();

    let navigation = lock_live_navigation(&workspace.scene).expect("scene is live");
    workspace
        .publish_saved_ssh_host(&navigation, Some(config.id()), &edited)
        .expect("publish connection edit");

    assert!(cancellation.is_cancelled());
    assert!(constructive_cancellation.is_cancelled());
    let snapshot = workspace.snapshot();
    assert_eq!(snapshot.selected_host(), Some(edited_id.as_str()));
    assert_eq!(snapshot.hosts().len(), 1);
    assert_eq!(snapshot.hosts()[0].id(), edited_id);
    assert_eq!(
        snapshot.hosts()[0].connection(),
        HostConnectionState::Unavailable
    );
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one linear proof that two scenes over one runtime stay independent"
)]
fn two_scenes_over_one_runtime_stay_independent() {
    let refresh_runtime = Arc::new(ManualRefreshRuntime::default());
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let a = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
        Arc::new(SystemWslDiscovery::new()),
        refresh_runtime,
    );
    a.scene
        .runtime
        .hosts
        .write()
        .expect("host list")
        .push(HostItem::ssh(
            "ssh:build",
            "build",
            "build.example",
            HostConnectionState::Disconnected,
            Vec::new(),
            None,
        ));
    let host = WslHost::new(
        config,
        Arc::new(StdCommandRunner) as SharedCommandRunner,
        executable,
    );
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot",
        42,
        vec![session::DiscoveredSession::new(
            "work",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    );
    *a.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host,
            snapshot: snapshot.clone(),
        },
        1,
    ));
    set_inventory_state(&a.scene.runtime, &ready_content(&snapshot));

    let b = a.open_scene();
    assert_ne!(a.scene.id, b.scene.id, "each scene gets its own identity");
    assert_eq!(
        a.scene.runtime.scenes.lock().expect("scene registry").len(),
        2,
        "both scenes are registered on the shared runtime"
    );

    b.select_host("ssh:build")
        .expect("scene B selects SSH host");
    let a_before = a.snapshot();
    let b_before = b.snapshot();
    assert_eq!(b_before.selected_host(), Some("ssh:build"));
    assert!(matches!(b_before.content(), WorkspaceContent::Shell));

    // Scene A selects the WSL host, resizes, raises a notice, and attaches.
    a.select_host("wsl").expect("scene A selects WSL");
    a.resize(120, 48).expect("scene A resizes its viewer");
    publish_local_notice(&a.scene, "scene A notice".to_owned());
    set_scene_state(
        &a.scene,
        WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "work".to_owned(),
            kind: SessionKind::Tmux,
            presentation_id: 7,
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(
                1,
                GridSize::new(120, 48).expect("valid grid"),
            ))),
        },
    );

    let a_attached = a.snapshot();
    assert!(matches!(
        a_attached.content(),
        WorkspaceContent::Terminal { session, .. } if session == "work"
    ));
    assert_eq!(a_attached.selected_host(), Some("wsl"));
    assert_eq!(a_attached.notice(), Some("scene A notice"));
    assert!(
        a_attached.revision() > a_before.revision(),
        "scene A observes its own changes"
    );

    // Scene B is untouched by A's activity.
    let b_after_a = b.snapshot();
    assert!(matches!(b_after_a.content(), WorkspaceContent::Shell));
    assert_eq!(b_after_a.selected_host(), Some("ssh:build"));
    assert_eq!(b_after_a.notice(), None);
    assert_eq!(
        b_after_a.revision(),
        b_before.revision(),
        "scene A activity does not advance scene B revisions"
    );
    let b_geometry = *b.scene.terminal_geometry.lock().expect("scene B geometry");
    assert_eq!(b_geometry.sequence, 0, "scene A resizes stay in scene A");
    let a_geometry = *a.scene.terminal_geometry.lock().expect("scene A geometry");
    assert_eq!(a_geometry.grid, GridSize::new(120, 48).expect("valid grid"));

    // Scene B activity does not leak into scene A either.
    publish_local_notice(&b.scene, "scene B notice".to_owned());
    set_scene_state(
        &b.scene,
        WorkspaceContent::Attaching {
            host_id: "ssh:build".to_owned(),
            endpoint: "build.example".to_owned(),
            session: "remote".to_owned(),
            kind: SessionKind::Tmux,
        },
    );
    let a_after_b = a.snapshot();
    assert!(matches!(
        a_after_b.content(),
        WorkspaceContent::Terminal { session, .. } if session == "work"
    ));
    assert_eq!(a_after_b.selected_host(), Some("wsl"));
    assert_eq!(a_after_b.notice(), Some("scene A notice"));
    assert_eq!(
        a_after_b.revision(),
        a_attached.revision(),
        "scene B activity does not advance scene A revisions"
    );
    let b_switched = b.snapshot();
    assert!(matches!(
        b_switched.content(),
        WorkspaceContent::Attaching { session, .. } if session == "remote"
    ));
    assert!(b_switched.revision() > b_after_a.revision());

    // A runtime inventory broadcast reaches both scenes.
    let refreshed = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot",
        42,
        vec![session::DiscoveredSession::new(
            "fresh",
            session::SessionIdentity::new(101, "$2", 201),
            0,
        )],
    );
    set_inventory_state(&a.scene.runtime, &ready_content(&refreshed));
    let a_broadcast = a.snapshot();
    let b_broadcast = b.snapshot();
    for snapshot in [&a_broadcast, &b_broadcast] {
        let wsl = snapshot
            .hosts()
            .iter()
            .find(|host| host.id() == "wsl")
            .expect("WSL host row");
        assert_eq!(wsl.sessions().len(), 1);
        assert_eq!(wsl.sessions()[0].name(), "fresh");
    }
    assert!(
        a_broadcast.revision() > a_after_b.revision(),
        "the broadcast advances scene A"
    );
    assert!(
        b_broadcast.revision() > b_switched.revision(),
        "the broadcast advances scene B"
    );
    assert!(matches!(
        a_broadcast.content(),
        WorkspaceContent::Terminal { .. }
    ));
    assert!(matches!(
        b_broadcast.content(),
        WorkspaceContent::Attaching { .. }
    ));

    // Dropping a scene removes it from the registry on the next broadcast.
    drop(b);
    set_inventory_state(&a.scene.runtime, &ready_content(&refreshed));
    assert_eq!(
        a.scene.runtime.scenes.lock().expect("scene registry").len(),
        1,
        "dead scenes are pruned from the registry"
    );
}

#[test]
fn legacy_inventory_broadcast_projects_into_every_scene() {
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("existing", 0)],
    ));
    let b = a.open_scene();
    assert!(matches!(
        b.snapshot().content(),
        WorkspaceContent::Ready { sessions, .. } if sessions.len() == 1
    ));

    set_scene_state(
        &a.scene,
        WorkspaceContent::Terminal {
            host_id: "wsl".to_owned(),
            endpoint: "Ubuntu".to_owned(),
            session: "existing".to_owned(),
            kind: SessionKind::Tmux,
            presentation_id: 3,
            surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(
                1,
                GridSize::new(80, 24).expect("valid grid"),
            ))),
        },
    );
    let b_before = b.snapshot();
    publish_legacy_inventory_state(
        &a.scene.runtime,
        &WorkspaceContent::Ready {
            endpoint: "Ubuntu".to_owned(),
            sessions: vec![SessionItem::new("replacement", 0)],
        },
    );

    assert!(
        matches!(
            a.snapshot().content(),
            WorkspaceContent::Terminal { session, .. } if session == "existing"
        ),
        "a scene presenting a terminal keeps its presentation"
    );
    let b_after = b.snapshot();
    assert!(
        matches!(
            b_after.content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.len() == 1 && sessions[0].name() == "replacement"
        ),
        "a scene on inventory content receives the broadcast"
    );
    assert!(b_after.revision() > b_before.revision());
}

#[test]
fn concurrent_scene_presentations_resize_and_detach_independently() {
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("work", 0), SessionItem::new("fresh", 0)],
    ));
    let b = a.open_scene();
    let terminal = |session: &str, presentation_id| WorkspaceContent::Terminal {
        host_id: "wsl".to_owned(),
        endpoint: "Ubuntu".to_owned(),
        session: session.to_owned(),
        kind: SessionKind::Tmux,
        presentation_id,
        surface: Arc::new(SurfaceStore::new(surface::SurfaceFrame::blank(
            1,
            GridSize::new(80, 24).expect("valid grid"),
        ))),
    };
    set_scene_state(&a.scene, terminal("work", 7));
    set_scene_state(&b.scene, terminal("fresh", 8));

    // Each scene's viewer geometry advances independently.
    a.resize(120, 48).expect("scene A resizes");
    a.resize(132, 50).expect("scene A resizes again");
    b.resize(90, 30).expect("scene B resizes");
    let a_geometry = *a.scene.terminal_geometry.lock().expect("scene A geometry");
    let b_geometry = *b.scene.terminal_geometry.lock().expect("scene B geometry");
    assert_eq!(a_geometry.sequence, 2);
    assert_eq!(b_geometry.sequence, 1);
    assert_eq!(a_geometry.grid, GridSize::new(132, 50).expect("valid grid"));
    assert_eq!(b_geometry.grid, GridSize::new(90, 30).expect("valid grid"));

    // Scene A detaching tears down only scene A's presentation.
    let b_before_detach = b.snapshot();
    a.detach();
    assert!(matches!(
        a.snapshot().content(),
        WorkspaceContent::Ready { .. }
    ));
    let b_after_detach = b.snapshot();
    assert!(
        matches!(
            b_after_detach.content(),
            WorkspaceContent::Terminal { session, presentation_id, .. }
                if session == "fresh" && *presentation_id == 8
        ),
        "scene A's detach leaves scene B's presentation live"
    );
    assert_eq!(
        b_after_detach.revision(),
        b_before_detach.revision(),
        "scene A's detach does not re-render scene B"
    );
    assert_eq!(
        b.scene.terminal_geometry.lock().expect("geometry").sequence,
        1,
        "scene A's detach leaves scene B's geometry sequence alone"
    );
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one linear proof that stale and current publications differ across scenes"
)]
fn stale_generation_remote_publication_cannot_touch_another_scenes_presentation() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let b = a.open_scene();
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let host = remote_host_fixture(&config);
    let identity = session::SessionIdentity::new(42, "$1", 100);
    let snapshot = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        8,
        vec![session::DiscoveredSession::new("work", identity.clone(), 0)],
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );
    a.scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: Some(host.clone()),
                context: Some(RemoteHostContext {
                    generation: 8,
                    host: host.clone(),
                    snapshot: snapshot.clone(),
                }),
                cancellation: None,
                constructive_cancellation: None,
                attachment_attempts: Vec::new(),
                generation: 8,
            },
        );
    // Scene B presents the remote session keyed to the current connection.
    *b.scene.remote_active.lock().expect("scene B remote active") = Some(RemoteActive {
        key: RemotePresentationKey {
            host_id: "ssh:studio".to_owned(),
            endpoint: "studio.example".to_owned(),
            route_identity: TEST_REMOTE_ROUTE.to_owned(),
            lease_generation: 8,
            session_identity: RemoteSessionIdentity::Tmux(identity.clone()),
        },
        selection: SessionSelection::new("ssh:studio", "studio.example", "work"),
        worker_generation: 99,
        lease: snapshot.lease().clone(),
        presentation_id: 42,
        term: AttachTerm::Xterm256Color,
        retainable: true,
        identity_mismatch_marker: None,
    });
    let b_revision = b.snapshot().revision();

    // A stale-generation publication driven through scene A returns before
    // reconciling any scene: scene B's presentation is untouched.
    let stale_snapshot = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        7,
        Vec::new(),
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );
    publish_remote_connection(
        &a.scene,
        "ssh:studio",
        7,
        Ok((host.clone(), stale_snapshot)),
    );
    {
        let active = b.scene.remote_active.lock().expect("scene B remote active");
        let active = active.as_ref().expect("presentation survives");
        assert!(
            active.retainable,
            "a stale publication cannot mark it stale"
        );
        assert_eq!(active.selection.session(), "work");
    }
    assert_eq!(
        b.snapshot().revision(),
        b_revision,
        "a stale-generation publication does not re-render scene B"
    );

    // A current-generation publication is inventory reality and does cross
    // scenes: the session vanished, so scene B's presentation goes stale.
    let empty = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        8,
        Vec::new(),
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );
    publish_remote_connection(&a.scene, "ssh:studio", 8, Ok((host, empty)));
    let active = b.scene.remote_active.lock().expect("scene B remote active");
    assert!(
        !active
            .as_ref()
            .expect("presentation object remains")
            .retainable,
        "current inventory reality still reconciles every scene"
    );
}

#[cfg(windows)]
#[test]
fn confirmed_kill_in_one_scene_closes_matching_presentations_everywhere() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new("work", identity.clone(), 0)],
    );
    let request = attach_request_fixture(&snapshot, identity.clone(), "work");
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("work", 0)],
    ));
    let b = a.open_scene();
    for scene in [&a.scene, &b.scene] {
        scene
            .attachment
            .lock()
            .expect("attachment")
            .reserve(request.clone(), AttachTerm::Xterm256Color)
            .expect("reserve attachment");
    }

    // The kill lands through scene A, but the session's death is a
    // host-wide fact: every scene's matching presentation closes.
    a.finish_session_kill(&LiveSessionTarget::test_fixture(
        &snapshot, "work", identity,
    ));

    for (label, workspace) in [("A", &a), ("B", &b)] {
        assert!(
            workspace
                .scene
                .attachment
                .lock()
                .expect("attachment")
                .active()
                .is_none(),
            "scene {label}'s presentation of the killed session is closed"
        );
        assert!(matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { .. }
        ));
    }
}

#[cfg(windows)]
#[test]
fn completed_tmux_kill_drops_matching_confirmations_in_every_scene() {
    let work = session::SessionIdentity::new(100, "$1", 200);
    let other = session::SessionIdentity::new(101, "$2", 201);
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![
            session::DiscoveredSession::new("work", work.clone(), 0),
            session::DiscoveredSession::new("other", other.clone(), 0),
        ],
    );
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(RefusingRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("work", 0), SessionItem::new("other", 0)],
    ));
    let b = a.open_scene();
    let c = a.open_scene();
    let pending = |scene: &Scene, name: &str, identity: &session::SessionIdentity| PendingKill {
        generation: scene.kill_generation.load(Ordering::Acquire),
        selection: SessionSelection::new("wsl", "Ubuntu", name),
        host: host.clone(),
        target: KillTarget::Tmux(Arc::new(LiveSessionTarget::test_fixture(
            &snapshot,
            name,
            identity.clone(),
        ))),
    };
    assert!(publish_pending_kill(
        &b.scene,
        pending(&b.scene, "work", &work)
    ));
    assert!(publish_pending_kill(
        &c.scene,
        pending(&c.scene, "other", &other)
    ));
    let b_revision = b.snapshot().revision();
    let c_revision = c.snapshot().revision();

    // The kill completes through scene A; the session is gone host-wide.
    a.finish_session_kill(&LiveSessionTarget::test_fixture(&snapshot, "work", work));

    assert_eq!(
        b.session_kill_confirmation(),
        None,
        "the completed kill drops scene B's matching confirmation"
    );
    assert!(
        b.snapshot().revision() > b_revision,
        "dropping the stale confirmation re-renders scene B"
    );
    assert!(
        c.session_kill_confirmation().is_some(),
        "scene C's confirmation for an unrelated session stays valid"
    );
    assert_eq!(
        c.snapshot().revision(),
        c_revision,
        "scene C is not re-rendered by an unrelated kill"
    );
}

#[cfg(windows)]
#[test]
fn completed_zellij_kill_drops_matching_confirmations_in_every_scene() {
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(RefusingRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let b = a.open_scene();
    let c = a.open_scene();
    let pending = |scene: &Scene, name: &str| PendingKill {
        generation: scene.kill_generation.load(Ordering::Acquire),
        selection: SessionSelection::zellij("wsl", "Ubuntu", name),
        host: host.clone(),
        target: KillTarget::Zellij {
            endpoint: snapshot.endpoint().clone(),
            runtime: snapshot.runtime().clone(),
            executable: "/usr/bin/zellij".to_owned(),
            name: name.to_owned(),
            revision: 0,
        },
    };
    assert!(publish_pending_kill(&b.scene, pending(&b.scene, "review")));
    assert!(publish_pending_kill(&c.scene, pending(&c.scene, "other")));
    let c_revision = c.snapshot().revision();

    a.finish_zellij_presentation(snapshot.endpoint(), snapshot.runtime(), "review");

    assert_eq!(
        b.session_kill_confirmation(),
        None,
        "the completed Zellij kill drops scene B's matching confirmation"
    );
    assert!(
        c.session_kill_confirmation().is_some(),
        "scene C's confirmation for an unrelated Zellij session stays valid"
    );
    assert_eq!(c.snapshot().revision(), c_revision);
}

#[cfg(windows)]
#[test]
fn completed_herdr_lifecycle_drops_matching_confirmations_in_every_scene() {
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(RefusingRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let b = a.open_scene();
    let c = a.open_scene();
    let record = |name: &str| {
        session::HerdrSessionRecord::new(
            name,
            false,
            HerdrSessionState::Running,
            "/srv/herdr/sessions",
            "/srv/herdr/sessions/herdr.sock",
        )
    };
    let pending = |scene: &Scene, name: &str, operation_id| PendingHerdrLifecycle {
        generation: scene.herdr_lifecycle_generation.load(Ordering::Acquire),
        operation_id,
        selection: SessionSelection::herdr("wsl", "Ubuntu", name),
        action: HerdrLifecycleAction::Stop,
        host: host.clone(),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        executable: "/usr/bin/herdr".to_owned(),
        record: record(name),
    };
    *b.scene
        .pending_herdr_lifecycle
        .lock()
        .expect("scene B pending lifecycle") = Some(pending(&b.scene, "agents", 1));
    *c.scene
        .pending_herdr_lifecycle
        .lock()
        .expect("scene C pending lifecycle") = Some(pending(&c.scene, "other", 2));
    assert!(b.herdr_lifecycle_confirmation().is_some());
    let c_revision = c.snapshot().revision();

    a.finish_herdr_presentation(snapshot.endpoint(), snapshot.runtime(), &record("agents"));

    assert_eq!(
        b.herdr_lifecycle_confirmation(),
        None,
        "the completed Herdr mutation drops scene B's matching confirmation"
    );
    assert!(
        c.herdr_lifecycle_confirmation().is_some(),
        "scene C's confirmation for an unrelated Herdr session stays valid"
    );
    assert_eq!(c.snapshot().revision(), c_revision);
}

#[test]
fn removed_kwt_worktree_drops_matching_confirmations_in_every_scene() {
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let b = a.open_scene();
    let c = a.open_scene();
    let generation = "0123456789abcdef0123456789abcdef";
    let pending = |scene: &Scene, worktree_path: &str| PendingKwtRemoval {
        authority: scene.kwt_removal_generation.load(Ordering::Acquire),
        endpoint: snapshot.endpoint().clone(),
        repository: "github.com/acme/widget".to_owned(),
        project_path: "/code/widget".to_owned(),
        registration_fingerprint: "registration".to_owned(),
        worktree_path: worktree_path.to_owned(),
        generation: generation.to_owned(),
        session_name: "widget-topic".to_owned(),
        socket_name: None,
        live_target: None,
    };
    *b.scene
        .pending_kwt_removal
        .lock()
        .expect("scene B pending removal") = Some(pending(&b.scene, "/work/widget/topic"));
    *c.scene
        .pending_kwt_removal
        .lock()
        .expect("scene C pending removal") = Some(pending(&c.scene, "/work/widget/other"));
    let b_revision = b.snapshot().revision();
    let c_revision = c.snapshot().revision();

    drop_matching_kwt_removal_confirmations(
        &a.scene.runtime,
        snapshot.endpoint(),
        "github.com/acme/widget",
        "/code/widget",
        "registration",
        "/work/widget/topic",
        generation,
    );

    assert!(
        b.scene
            .pending_kwt_removal
            .lock()
            .expect("scene B pending removal")
            .is_none(),
        "the completed removal drops scene B's matching confirmation"
    );
    assert!(
        b.snapshot().revision() > b_revision,
        "dropping the stale confirmation re-renders scene B"
    );
    assert!(
        c.scene
            .pending_kwt_removal
            .lock()
            .expect("scene C pending removal")
            .is_some(),
        "scene C's confirmation for an unrelated worktree stays valid"
    );
    assert_eq!(c.snapshot().revision(), c_revision);
}

#[cfg(windows)]
#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one linear proof across every removal-reconciliation branch"
)]
fn kwt_removal_reconciliation_branches_gate_confirmation_drops() {
    fn widget_inventory(with_topic_worktree: bool) -> KwtInventory {
        let worktrees: &[u8] = if with_topic_worktree {
            br#"[{"path":"/work/widget/topic","branch":"topic","commit_hash":"abc","is_main":false,"created_at":null,"generation":"0123456789abcdef0123456789abcdef","repository":"github.com/acme/widget","session_name":"widget-topic","tmux_socket_name":null}]"#
        } else {
            b"[]"
        };
        KwtInventory::parse(
            br#"[{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget","last_touched":null,"registration_fingerprint":"registration"}]"#,
            worktrees,
            b"[]",
        )
        .expect("valid KWT inventory")
    }
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let b = a.open_scene();
    let generation = "0123456789abcdef0123456789abcdef";
    let worktree_path = "/work/widget/topic";
    let install_pending = |scene: &Scene| {
        *scene.pending_kwt_removal.lock().expect("pending removal") = Some(PendingKwtRemoval {
            authority: scene.kwt_removal_generation.load(Ordering::Acquire),
            endpoint: snapshot.endpoint().clone(),
            repository: "github.com/acme/widget".to_owned(),
            project_path: "/code/widget".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            worktree_path: worktree_path.to_owned(),
            generation: generation.to_owned(),
            session_name: "widget-topic".to_owned(),
            socket_name: None,
            live_target: None,
        });
    };
    let pending_survives = || {
        b.scene
            .pending_kwt_removal
            .lock()
            .expect("scene B pending removal")
            .is_some()
    };
    let reported_failure_with = |needle: &str| {
        let (events, _) = a.drain_events();
        events.iter().any(|event| {
            matches!(
                event,
                WorkspaceEvent::KwtWorktreeOperationFailed { message, .. }
                    if message.contains(needle)
            )
        })
    };
    let reported_removed = || {
        let (events, _) = a.drain_events();
        events
            .iter()
            .any(|event| matches!(event, WorkspaceEvent::KwtWorktreeRemoved { .. }))
    };
    install_pending(&b.scene);
    let task = KwtWorktreeTask {
        // No pinned KWT bundle in this configuration: the integrated
        // reconciliation's real discovery reports inventory unavailable
        // without executing any command.
        host: WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            Arc::new(RefusingRunner) as SharedCommandRunner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        ),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        cancellation: CancellationToken::new(),
        generation: a
            .scene
            .runtime
            .kwt_refresh_generation
            .load(Ordering::Acquire),
        operation_id: 9,
        repository: "github.com/acme/widget".to_owned(),
        project_path: "/code/widget".to_owned(),
        registration_fingerprint: "registration".to_owned(),
        operation: KwtWorktreeOperation::Remove {
            worktree_path: worktree_path.to_owned(),
            generation: generation.to_owned(),
            session_name: "widget-topic".to_owned(),
            socket_name: None,
            live_target: None,
            operation_id: 9,
        },
    };
    // A real classified host error, produced without any command: the
    // relative project path is rejected before KWT is consulted.
    let discovery_error = || {
        task.host
            .register_kwt_project(
                &task.endpoint,
                &task.runtime,
                "relative/path",
                &CancellationToken::new(),
            )
            .expect_err("a relative project path yields a host error")
    };

    // KWT's own success report (the tombstone) is not removal
    // confirmation: scene B's dialog survives it.
    tombstone_removed_kwt_worktree(&a.scene, &task, worktree_path, generation);
    assert!(
        pending_survives(),
        "an unverified success report preserves other scenes' confirmations"
    );

    // The integrated post-success reconciliation with real discovery
    // (inventory unavailable) reports the removal but preserves dialogs.
    assert!(reconcile_removed_kwt_worktree(
        &a.scene,
        &task,
        worktree_path,
        generation
    ));
    assert!(
        pending_survives(),
        "an unverifiable reconciliation preserves other scenes' confirmations"
    );
    let _drained = a.drain_events();

    // Post-success reconciliation, every discovery outcome.
    assert!(!settle_removed_kwt_worktree(
        &a.scene,
        &task,
        worktree_path,
        generation,
        Ok(Some(widget_inventory(true))),
    ));
    assert!(
        pending_survives(),
        "post-success: a still-present worktree preserves confirmations"
    );
    assert!(
        reported_failure_with("still present"),
        "post-success: the still-present outcome reports a failure"
    );

    assert!(settle_removed_kwt_worktree(
        &a.scene,
        &task,
        worktree_path,
        generation,
        Ok(None),
    ));
    assert!(
        pending_survives(),
        "post-success: unavailable inventory preserves confirmations"
    );
    assert!(
        reported_removed(),
        "post-success: unavailable inventory still reports the removal"
    );

    assert!(settle_removed_kwt_worktree(
        &a.scene,
        &task,
        worktree_path,
        generation,
        Err(discovery_error()),
    ));
    assert!(
        pending_survives(),
        "post-success: a discovery error preserves confirmations"
    );
    assert!(
        reported_removed(),
        "post-success: a discovery error still reports the removal"
    );

    assert!(settle_removed_kwt_worktree(
        &a.scene,
        &task,
        worktree_path,
        generation,
        Ok(Some(widget_inventory(false))),
    ));
    assert!(
        !pending_survives(),
        "post-success: only the verified absence drops the confirmation"
    );
    assert!(
        reported_removed(),
        "post-success: the verified absence reports the removal"
    );

    // Timed-out reconciliation, every discovery outcome.
    install_pending(&b.scene);
    settle_timed_out_kwt_worktree_remove(
        &a.scene,
        &task,
        worktree_path,
        generation,
        false,
        Ok(Some(widget_inventory(true))),
    );
    assert!(
        pending_survives(),
        "timed out: a still-present worktree preserves confirmations"
    );
    assert!(
        reported_failure_with("KWT still reports the worktree"),
        "timed out: the still-present outcome reports a failure"
    );

    settle_timed_out_kwt_worktree_remove(
        &a.scene,
        &task,
        worktree_path,
        generation,
        false,
        Ok(None),
    );
    assert!(
        pending_survives(),
        "timed out: unavailable inventory preserves confirmations"
    );
    assert!(
        reported_failure_with("temporarily unavailable"),
        "timed out: unavailable inventory reports a failure"
    );

    settle_timed_out_kwt_worktree_remove(
        &a.scene,
        &task,
        worktree_path,
        generation,
        false,
        Err(discovery_error()),
    );
    assert!(
        pending_survives(),
        "timed out: a discovery error preserves confirmations"
    );
    assert!(
        reported_failure_with("could not be confirmed"),
        "timed out: a discovery error reports a failure"
    );

    settle_timed_out_kwt_worktree_remove(
        &a.scene,
        &task,
        worktree_path,
        generation,
        false,
        Ok(Some(widget_inventory(false))),
    );
    assert!(
        !pending_survives(),
        "timed out: only the verified absence drops the confirmation"
    );
    assert!(
        reported_removed(),
        "timed out: the verified absence reports the removal"
    );
}

#[cfg(windows)]
#[test]
fn kill_completing_during_identity_capture_cannot_publish_a_stale_confirmation() {
    let work = session::SessionIdentity::new(100, "$1", 200);
    let other = session::SessionIdentity::new(101, "$2", 201);
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![
            session::DiscoveredSession::new("work", work.clone(), 0),
            session::DiscoveredSession::new("other", other.clone(), 0),
        ],
    );
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(RefusingRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("work", 0), SessionItem::new("other", 0)],
    ));
    a.scene
        .runtime
        .hosts
        .write()
        .expect("host list")
        .push(HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Ready,
            vec![SessionItem::new("work", 0), SessionItem::new("other", 0)],
            None,
        ));
    *a.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: host.clone(),
            snapshot: snapshot.clone(),
        },
        1,
    ));
    let b = a.open_scene();
    let c = a.open_scene();

    // Both scenes start asynchronous identity captures before any kill
    // completes; each records its capture intent.
    b.request_session_kill(&SessionSelection::new("wsl", "Ubuntu", "work"))
        .expect("scene B starts a kill capture");
    c.request_session_kill(&SessionSelection::new("wsl", "Ubuntu", "other"))
        .expect("scene C starts a kill capture");
    let b_generation = b.scene.kill_generation.load(Ordering::Acquire);
    let c_generation = c.scene.kill_generation.load(Ordering::Acquire);

    // The kill of "work" completes through scene A while the captures are
    // still in flight.
    a.finish_session_kill(&LiveSessionTarget::test_fixture(
        &snapshot,
        "work",
        work.clone(),
    ));

    // A capture that straddled the kill publishes exactly this call; the
    // advanced fence rejects it instead of resurrecting a dialog for the
    // dead session.
    assert!(
        !publish_pending_kill(
            &b.scene,
            PendingKill {
                generation: b_generation,
                selection: SessionSelection::new("wsl", "Ubuntu", "work"),
                host: host.clone(),
                target: KillTarget::Tmux(Arc::new(LiveSessionTarget::test_fixture(
                    &snapshot, "work", work,
                ))),
            },
        ),
        "a capture that straddled the kill cannot publish"
    );
    assert_eq!(b.session_kill_confirmation(), None);

    // Scene C's capture targets a different session: its fence is
    // untouched and its confirmation still publishes.
    assert!(
        publish_pending_kill(
            &c.scene,
            PendingKill {
                generation: c_generation,
                selection: SessionSelection::new("wsl", "Ubuntu", "other"),
                host,
                target: KillTarget::Tmux(Arc::new(LiveSessionTarget::test_fixture(
                    &snapshot, "other", other,
                ))),
            },
        ),
        "an unrelated in-flight capture still publishes"
    );
    assert!(c.session_kill_confirmation().is_some());
}

#[cfg(windows)]
#[test]
fn superseded_kill_request_cannot_overwrite_the_newer_captures_intent() {
    let work = session::SessionIdentity::new(100, "$1", 200);
    let other = session::SessionIdentity::new(101, "$2", 201);
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![
            session::DiscoveredSession::new("work", work.clone(), 0),
            session::DiscoveredSession::new("other", other.clone(), 0),
        ],
    );
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(RefusingRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("work", 0), SessionItem::new("other", 0)],
    ));
    a.scene
        .runtime
        .hosts
        .write()
        .expect("host list")
        .push(HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Ready,
            vec![SessionItem::new("work", 0), SessionItem::new("other", 0)],
            None,
        ));
    *a.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: host.clone(),
            snapshot: snapshot.clone(),
        },
        1,
    ));
    let b = a.open_scene();

    // Two overlapping kill requests: the older one's capture task is still
    // starting when the newer request supersedes it.
    b.request_session_kill(&SessionSelection::new("wsl", "Ubuntu", "work"))
        .expect("older kill request");
    let older_generation = b.scene.kill_generation.load(Ordering::Acquire);
    b.request_session_kill(&SessionSelection::new("wsl", "Ubuntu", "other"))
        .expect("newer kill request");
    let newer_generation = b.scene.kill_generation.load(Ordering::Acquire);
    assert!(newer_generation > older_generation);

    // Registration is atomic with minting, so the newer request's mint
    // already replaced the older capture's intent; there is no late
    // registration path left for the older request to re-assert itself.
    {
        let intent = b.scene.kill_capture_intent.lock().expect("capture intent");
        let intent = intent
            .as_ref()
            .expect("the newer capture's intent survives");
        assert_eq!(
            intent.generation, newer_generation,
            "the stale registration is refused"
        );
        assert_eq!(intent.selection.session(), "other");
    }

    // A completed kill of the older target therefore fences nothing here:
    // the newer capture for "other" stays publishable.
    a.finish_session_kill(&LiveSessionTarget::test_fixture(&snapshot, "work", work));
    assert_eq!(
        b.scene.kill_generation.load(Ordering::Acquire),
        newer_generation,
        "the unrelated kill leaves the newer capture's fence alone"
    );
    assert!(
        publish_pending_kill(
            &b.scene,
            PendingKill {
                generation: newer_generation,
                selection: SessionSelection::new("wsl", "Ubuntu", "other"),
                host,
                target: KillTarget::Tmux(Arc::new(LiveSessionTarget::test_fixture(
                    &snapshot, "other", other,
                ))),
            },
        ),
        "the newer capture still publishes its confirmation"
    );
    assert!(b.session_kill_confirmation().is_some());
}

#[test]
fn kill_intent_minting_is_atomic_with_the_fence() {
    // Registration shares the minting critical section, so there is no
    // window in which a generation exists without its intent, and a newer
    // mint atomically replaces the older capture's intent.
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let b = a.open_scene();

    let older = invalidate_pending_kill_with_intent(
        &b.scene,
        &SessionSelection::new("wsl", "Ubuntu", "work"),
    );
    {
        let intent = b.scene.kill_capture_intent.lock().expect("capture intent");
        let intent = intent.as_ref().expect("mint installs its intent");
        assert_eq!(intent.generation, older);
        assert_eq!(intent.selection.session(), "work");
    }

    let newer = invalidate_pending_kill_with_intent(
        &b.scene,
        &SessionSelection::new("wsl", "Ubuntu", "other"),
    );
    assert!(newer > older);
    {
        let intent = b.scene.kill_capture_intent.lock().expect("capture intent");
        let intent = intent.as_ref().expect("the newer mint installs its intent");
        assert_eq!(intent.generation, newer, "the older intent is replaced");
        assert_eq!(intent.selection.session(), "other");
    }
}

#[test]
fn concurrent_zellij_kill_confirmations_for_one_target_are_refused() {
    // Two scenes hold confirmed dialogs for the same Zellij session. The
    // second confirmation must be refused at reservation instead of
    // queuing behind the first on the operation lane, where it would kill
    // whatever same-name replacement discovery finds next.
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(RefusingRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let b = a.open_scene();
    let target = || KillTarget::Zellij {
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        executable: "/usr/bin/zellij".to_owned(),
        name: "review".to_owned(),
        revision: 0,
    };
    for scene in [&a, &b] {
        let generation = invalidate_pending_kill(&scene.scene);
        assert!(publish_pending_kill(
            &scene.scene,
            PendingKill {
                generation,
                selection: SessionSelection::zellij("wsl", "Ubuntu", "review"),
                host: host.clone(),
                target: target(),
            },
        ));
    }

    // Park the first confirmation's task on the operation lane so the
    // second confirmation arrives while the first is provably in flight.
    let operations = a
        .scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    a.confirm_session_kill()
        .expect("the first confirmation reserves the target");
    let refusal = b
        .confirm_session_kill()
        .expect_err("the duplicate confirmation is refused");
    assert!(
        refusal.to_string().contains("already in progress"),
        "{refusal}"
    );
    drop(operations);

    // The parked task fails against the refusing runner and releases the
    // reservation; the target becomes reservable again.
    settle("the first kill task settles", || {
        let (events, _) = a.drain_events();
        events
            .iter()
            .any(|event| matches!(event, WorkspaceEvent::Error(_)))
    });
    let key = (
        snapshot.endpoint().distro().to_owned(),
        format!(
            "{}:{}",
            snapshot.runtime().kernel_boot_id(),
            snapshot.runtime().init_start_ticks()
        ),
        "review".to_owned(),
    );
    assert!(
        matches!(
            reserve_zellij_kill(&a.scene.runtime, key.clone(), 0),
            ZellijKillReservation::Reserved
        ),
        "a failed kill releases its reservation without advancing the revision"
    );
    release_zellij_kill(&a.scene.runtime, &key, false);
}

#[test]
fn a_completed_zellij_kill_advances_the_reservation_revision() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let runtime = &workspace.scene.runtime;
    let key = (
        "Ubuntu".to_owned(),
        "boot:1".to_owned(),
        "review".to_owned(),
    );

    let bound = zellij_kill_revision(runtime, &key);
    assert!(matches!(
        reserve_zellij_kill(runtime, key.clone(), bound),
        ZellijKillReservation::Reserved
    ));
    assert!(matches!(
        reserve_zellij_kill(runtime, key.clone(), bound),
        ZellijKillReservation::InFlight
    ));
    release_zellij_kill(runtime, &key, true);

    // A dialog created before the completed kill bound the old revision;
    // its reservation is refused as stale even though nothing is in
    // flight — the window between taking the confirmation and reserving
    // cannot resurrect it.
    assert!(matches!(
        reserve_zellij_kill(runtime, key.clone(), bound),
        ZellijKillReservation::Stale
    ));
    let rebound = zellij_kill_revision(runtime, &key);
    assert!(rebound > bound);
    assert!(matches!(
        reserve_zellij_kill(runtime, key.clone(), rebound),
        ZellijKillReservation::Reserved
    ));
    assert!(zellij_kill_is_current(runtime, &key, rebound));
    release_zellij_kill(runtime, &key, false);
}

#[test]
fn a_killed_zellij_session_leaves_shared_inventory_immediately() {
    // The kill's success path removes the session from the published
    // snapshot and the host item before the kill revision advances, and
    // fences in-flight refreshes whose snapshots predate the kill — stale
    // inventory must neither authorize a new kill against a same-name
    // replacement nor restore the dead name.
    let snapshot = HostSnapshot::test_fixture_with_zellij(
        "Ubuntu",
        "boot",
        42,
        Vec::new(),
        ZellijInventory::Available {
            executable: "/usr/bin/zellij".to_owned(),
            sessions: vec![session::ZellijSessionRecord::discovered("review")],
        },
    );
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(RefusingRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    {
        let mut hosts = workspace.scene.runtime.hosts.write().expect("host list");
        let item = hosts.first_mut().expect("wsl host");
        item.zellij_available = true;
        item.zellij_sessions = vec![SessionItem::new("review", 0)];
    }
    *workspace.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host,
            snapshot: snapshot.clone(),
        },
        1,
    ));

    // An in-flight refresh captured before the kill.
    let stale_generation = reserve_refresh(&workspace.scene.runtime, &CancellationToken::new());

    remove_killed_zellij_session(
        &workspace.scene.runtime,
        snapshot.endpoint(),
        snapshot.runtime(),
        "review",
    );

    let published = workspace.scene.runtime.host.lock().expect("published host");
    let context = published.as_ref().expect("host stays published");
    assert!(
        !matches!(
            context.value.snapshot.zellij(),
            ZellijInventory::Available { sessions, .. }
                if sessions.iter().any(|session| session.name() == "review")
        ),
        "the killed session leaves the published authority snapshot"
    );
    drop(published);
    assert!(
        workspace
            .scene
            .runtime
            .hosts
            .read()
            .expect("host list")
            .first()
            .expect("wsl host")
            .zellij_sessions
            .is_empty(),
        "the killed session leaves the host item"
    );
    assert!(
        !publish_refresh(&workspace.scene.runtime, stale_generation, || {
            panic!("a refresh captured before the kill must not publish");
        }),
        "the pre-kill refresh's publication is fenced"
    );
}

#[cfg(windows)]
#[test]
fn a_revoked_restart_never_launches_and_a_failed_kill_re_drives_it() {
    // A retained client of the doomed session sits in `restarting` with a
    // queued retry. Suppression must revoke the registration so the retry
    // launches nothing, and a failed kill must hand it back and drive a
    // fresh retry in the owning scene.
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let runner = Arc::new(CountingRefusingRunner(AtomicUsize::new(0)));
    let mut request = attach_request_fixture_with_runner(
        &snapshot,
        identity,
        "work",
        Arc::clone(&runner) as SharedCommandRunner,
    );
    request.target = AttachTarget::Zellij {
        executable: "/usr/bin/zellij".to_owned(),
        name: "work".to_owned(),
    };
    let retry = RetainedRetry {
        key: request.presentation_key(),
        request: request.clone(),
    };
    workspace
        .scene
        .retained_presentations
        .lock()
        .expect("retained presentations")
        .restarting
        .push(RetainedRestart {
            key: retry.key.clone(),
            selection: request.selection(),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm,
                generation: 1,
                fallback: None,
            },
            presentation_id: 7,
        });

    let suppressed =
        workspace.close_zellij_presentations(snapshot.endpoint(), snapshot.runtime(), "work");
    assert_eq!(suppressed.len(), 1);
    assert_eq!(
        suppressed[0].restarts.len(),
        1,
        "suppression revokes the restarting registration"
    );

    // The queued retry runs after the revocation: it must launch nothing.
    crate::scene::run_retained_retry(&workspace.scene, &retry);
    assert_eq!(
        runner.0.load(Ordering::Acquire),
        0,
        "a revoked registration executes no host command"
    );

    // The failed kill restores the registration to its owner and drives a
    // fresh retry there; against the refusing runner that retry fails and
    // surfaces in the owner's operation events.
    workspace.restore_suppressed_zellij_presentations(suppressed);
    settle(
        "the restored registration's retry runs in the owner",
        || runner.0.load(Ordering::Acquire) > 0,
    );
}

#[test]
fn a_confirmation_taken_before_a_completed_kill_cannot_reserve() {
    // The exact interleaving: scene B's dialog leaves its slot, then a
    // kill of the same target completes (advancing the revision) before B
    // reserves. B's confirmation must be refused as stale, not reserved
    // at the new revision.
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(RefusingRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let b = a.open_scene();
    let key = (
        snapshot.endpoint().distro().to_owned(),
        format!(
            "{}:{}",
            snapshot.runtime().kernel_boot_id(),
            snapshot.runtime().init_start_ticks()
        ),
        "review".to_owned(),
    );
    let generation = invalidate_pending_kill(&b.scene);
    let bound = zellij_kill_revision(&b.scene.runtime, &key);
    assert!(publish_pending_kill(
        &b.scene,
        PendingKill {
            generation,
            selection: SessionSelection::zellij("wsl", "Ubuntu", "review"),
            host,
            target: KillTarget::Zellij {
                endpoint: snapshot.endpoint().clone(),
                runtime: snapshot.runtime().clone(),
                executable: "/usr/bin/zellij".to_owned(),
                name: "review".to_owned(),
                revision: bound,
            },
        },
    ));

    // Another scene's kill of the same target completes now.
    assert!(matches!(
        reserve_zellij_kill(&a.scene.runtime, key.clone(), bound),
        ZellijKillReservation::Reserved
    ));
    release_zellij_kill(&a.scene.runtime, &key, true);

    let refusal = b
        .confirm_session_kill()
        .expect_err("the stale confirmation is refused");
    assert!(refusal.to_string().contains("killed after"), "{refusal}");
}

#[cfg(windows)]
#[test]
fn a_completed_zellij_kill_fences_a_straddling_kill_request() {
    // Zellij sessions have no stable generations, so a stale confirmation
    // may kill a same-name replacement. A completed Zellij kill must fence
    // a request caught between its intent mint and its publication, the
    // same way completed tmux kills fence identity captures.
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot", 42, Vec::new());
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(RefusingRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let b = a.open_scene();
    let selection = SessionSelection::for_kind("wsl", "Ubuntu", "review", SessionKind::Zellij);
    let generation = invalidate_pending_kill_with_intent(&b.scene, &selection);

    a.finish_zellij_presentation(snapshot.endpoint(), snapshot.runtime(), "review");

    assert!(
        b.scene
            .kill_capture_intent
            .lock()
            .expect("capture intent")
            .is_none(),
        "the completed kill clears the straddling request's intent"
    );
    let published = publish_pending_kill(
        &b.scene,
        PendingKill {
            generation,
            selection,
            host,
            target: KillTarget::Zellij {
                endpoint: snapshot.endpoint().clone(),
                runtime: snapshot.runtime().clone(),
                executable: "/usr/bin/zellij".to_owned(),
                name: "review".to_owned(),
                revision: 0,
            },
        },
    );
    assert!(
        !published,
        "the straddled request cannot publish a confirmation for the dead session"
    );
}

#[cfg(windows)]
#[test]
fn removal_completing_during_identity_capture_cannot_publish_a_stale_confirmation() {
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(RefusingRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let b = a.open_scene();
    let c = a.open_scene();
    let generation = "0123456789abcdef0123456789abcdef";
    let intent = |scene: &Scene, worktree_path: &str| KwtRemovalCaptureIntent {
        authority: scene.kwt_removal_generation.load(Ordering::Acquire),
        endpoint: snapshot.endpoint().clone(),
        repository: "github.com/acme/widget".to_owned(),
        project_path: "/code/widget".to_owned(),
        registration_fingerprint: "registration".to_owned(),
        worktree_path: worktree_path.to_owned(),
        generation: generation.to_owned(),
    };
    let capture = |scene: &Scene, worktree_path: &str| KwtRemovalCapture {
        host: host.clone(),
        authority: scene.kwt_removal_generation.load(Ordering::Acquire),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        repository: "github.com/acme/widget".to_owned(),
        project_path: "/code/widget".to_owned(),
        registration_fingerprint: "registration".to_owned(),
        worktree_path: worktree_path.to_owned(),
        generation: generation.to_owned(),
        session_name: "widget-topic".to_owned(),
        socket_name: None,
    };
    // Both scenes' removal requests recorded their capture intents (the
    // request registration writes exactly this shape) and the captured
    // authorities before the removal completed.
    *b.scene
        .kwt_removal_capture_intent
        .lock()
        .expect("scene B capture intent") = Some(intent(&b.scene, "/work/widget/topic"));
    *c.scene
        .kwt_removal_capture_intent
        .lock()
        .expect("scene C capture intent") = Some(intent(&c.scene, "/work/widget/other"));
    let b_capture = capture(&b.scene, "/work/widget/topic");
    let c_capture = capture(&c.scene, "/work/widget/other");

    // The confirmed removal of the topic worktree lands while both
    // captures are still in flight.
    drop_matching_kwt_removal_confirmations(
        &a.scene.runtime,
        snapshot.endpoint(),
        "github.com/acme/widget",
        "/code/widget",
        "registration",
        "/work/widget/topic",
        generation,
    );

    // The straddling capture's publication is fenced by the advanced
    // authority: no dialog and no removal-ready event appear in scene B.
    publish_captured_kwt_removal(&b.scene, b_capture, None);
    assert!(
        b.scene
            .pending_kwt_removal
            .lock()
            .expect("scene B pending removal")
            .is_none(),
        "a capture that straddled the removal cannot publish"
    );
    let (b_events, _) = b.drain_events();
    assert!(
        !b_events
            .iter()
            .any(|event| matches!(event, WorkspaceEvent::KwtWorktreeRemovalReady { .. })),
        "the fenced capture publishes no removal-ready event"
    );

    // Scene C's capture targets a different worktree and still publishes.
    publish_captured_kwt_removal(&c.scene, c_capture, None);
    assert!(
        c.scene
            .pending_kwt_removal
            .lock()
            .expect("scene C pending removal")
            .is_some(),
        "an unrelated in-flight capture still publishes"
    );
    let (c_events, _) = c.drain_events();
    assert!(
        c_events
            .iter()
            .any(|event| matches!(event, WorkspaceEvent::KwtWorktreeRemovalReady { .. })),
        "the unrelated capture publishes its removal-ready event"
    );
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one linear proof that a queued construction survives another scene's publication"
)]
fn queued_remote_construction_recaptures_newer_same_connection_inventory() {
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let host = remote_host_fixture(&config);
    let zellij_available = || ZellijInventory::Available {
        executable: "/usr/bin/zellij".to_owned(),
        sessions: Vec::new(),
    };
    let initial = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        7,
        Vec::new(),
        HerdrInventory::Unavailable,
        zellij_available(),
    );
    let request = RemoteZellijCreateRequest {
        host_id: config.id().to_owned(),
        connection_generation: 7,
        host: host.clone(),
        snapshot: initial.clone(),
        executable: "/usr/bin/zellij".to_owned(),
        name: ZellijSessionName::parse("review").expect("valid session name"),
    };
    let a = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let b = a.open_scene();
    let cancellation = CancellationToken::new();
    a.scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: Some(host.clone()),
                context: Some(RemoteHostContext {
                    generation: 7,
                    host,
                    snapshot: initial.clone(),
                }),
                cancellation: None,
                constructive_cancellation: Some(RemoteConstructiveState::Active {
                    scene: a.scene.id,
                    navigation_generation: 5,
                    cancellation: cancellation.clone(),
                    launched: Arc::new(AtomicBool::new(false)),
                    target: remote_zellij_target("review"),
                }),
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );

    // Scene B's attachment publishes newer same-connection inventory while
    // the construction waits for the operation lane.
    let published = publish_remote_inventory(
        &b.scene,
        "ssh:studio",
        7,
        &initial,
        &CancellationToken::new(),
        RemoteSessionInventory::test_fixture(
            Some("/usr/bin/tmux".to_owned()),
            vec![session::DiscoveredSession::new(
                "build",
                session::SessionIdentity::new(42, "$1", 100),
                0,
            )],
            HerdrInventory::Unavailable,
            zellij_available(),
        ),
    )
    .expect("scene B publishes attachment inventory");
    assert_eq!(published.inventory_generation(), 1);

    // The originally captured snapshot now reads as stale at the fence...
    assert!(
        with_current_remote_constructive(
            &a.scene.runtime,
            "ssh:studio",
            7,
            &request.snapshot,
            &cancellation,
            || Ok(()),
        )
        .is_err()
    );

    // ...but the queued construction recaptures the latest same-connection
    // snapshot, revalidates its target, and still launches.
    let recaptured = recapture_remote_zellij_create_request(&a.scene.runtime, &request)
        .expect("recapture against the newer inventory");
    assert_eq!(
        recaptured.snapshot.inventory_generation(),
        published.inventory_generation()
    );
    with_current_remote_constructive(
        &a.scene.runtime,
        "ssh:studio",
        7,
        &recaptured.snapshot,
        &cancellation,
        || Ok(()),
    )
    .expect("the queued construction still crosses the launch fence");

    // If the target itself appeared in the newer inventory, recapture fails
    // closed instead of launching a duplicate.
    publish_remote_inventory(
        &a.scene,
        "ssh:studio",
        7,
        &recaptured.snapshot,
        &CancellationToken::new(),
        RemoteSessionInventory::test_fixture(
            Some("/usr/bin/tmux".to_owned()),
            Vec::new(),
            HerdrInventory::Unavailable,
            ZellijInventory::Available {
                executable: "/usr/bin/zellij".to_owned(),
                sessions: vec![session::ZellijSessionRecord::discovered("review")],
            },
        ),
    )
    .expect("publish inventory containing the target");
    assert!(
        recapture_remote_zellij_create_request(&a.scene.runtime, &request).is_err(),
        "an occupied target name fails the recapture closed"
    );
}

/// Command runner that refuses every command while counting invocations,
/// so a test can prove a code path issued no host commands at all.
struct CountingRefusingRunner(AtomicUsize);

impl CommandRunner for CountingRefusingRunner {
    fn run(
        &self,
        _program: &std::ffi::OsStr,
        _args: &[std::ffi::OsString],
        _cancellation: &CancellationToken,
        _timeout: Duration,
    ) -> std::io::Result<host::CommandOutput> {
        self.0.fetch_add(1, Ordering::AcqRel);
        Err(std::io::Error::new(
            std::io::ErrorKind::ConnectionAborted,
            "fixture command refused",
        ))
    }
}

fn counted_remote_host(
    config: &RemoteTmuxConfig,
    runner: Arc<CountingRefusingRunner>,
) -> RuntimeRemoteHost {
    let controller =
        KwtSshExecutable::from_absolute(std::env::current_exe().expect("test executable path"))
            .expect("absolute controller path");
    let ssh = SshExecutable::system().expect("system SSH");
    RemoteTmuxHost::new(
        config.clone(),
        &controller,
        &ssh,
        runner as SharedCommandRunner,
    )
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one linear proof from queued registration through the production runner"
)]
fn queued_zellij_construction_consults_recaptured_inventory_before_launching() {
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let runner = Arc::new(CountingRefusingRunner(AtomicUsize::new(0)));
    let host = counted_remote_host(&config, Arc::clone(&runner));
    let initial = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        7,
        Vec::new(),
        HerdrInventory::Unavailable,
        ZellijInventory::Available {
            executable: "/usr/bin/zellij".to_owned(),
            sessions: Vec::new(),
        },
    );
    let request = RemoteZellijCreateRequest {
        host_id: config.id().to_owned(),
        connection_generation: 7,
        host: host.clone(),
        snapshot: initial.clone(),
        executable: "/usr/bin/zellij".to_owned(),
        name: ZellijSessionName::parse("review").expect("valid session name"),
    };
    let a = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let b = a.open_scene();
    let cancellation = CancellationToken::new();
    a.scene.navigation_generation.store(5, Ordering::Release);
    a.scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: Some(host.clone()),
                context: Some(RemoteHostContext {
                    generation: 7,
                    host,
                    snapshot: initial.clone(),
                }),
                cancellation: None,
                constructive_cancellation: Some(RemoteConstructiveState::Active {
                    scene: a.scene.id,
                    navigation_generation: 5,
                    cancellation: cancellation.clone(),
                    launched: Arc::new(AtomicBool::new(false)),
                    target: remote_zellij_target("review"),
                }),
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );

    // The test holds the operation lane, so the production runner blocks
    // at lane acquisition while scene B's attachment publishes newer
    // same-connection inventory in which the target name already exists.
    // Only a recapture performed after the lane can see that publication.
    let lane = a
        .scene
        .runtime
        .session_operations
        .lock()
        .expect("hold the operation lane");
    let launched = std::thread::scope(|threads| {
        let scene = Arc::clone(&a.scene);
        let runner_cancellation = cancellation.clone();
        let construction = threads.spawn(move || {
            let launched = AtomicBool::new(false);
            run_remote_zellij_create(&scene, &request, 5, &runner_cancellation, &launched);
            launched.load(Ordering::Acquire)
        });
        publish_remote_inventory(
            &b.scene,
            "ssh:studio",
            7,
            &initial,
            &CancellationToken::new(),
            RemoteSessionInventory::test_fixture(
                Some("/usr/bin/tmux".to_owned()),
                Vec::new(),
                HerdrInventory::Unavailable,
                ZellijInventory::Available {
                    executable: "/usr/bin/zellij".to_owned(),
                    sessions: vec![session::ZellijSessionRecord::discovered("review")],
                },
            ),
        )
        .expect("scene B publishes attachment inventory while the lane is held");
        drop(lane);
        construction.join().expect("the construction completes")
    });

    assert_eq!(
        runner.0.load(Ordering::Acquire),
        0,
        "the rejected construction never reaches the host"
    );
    assert!(!launched);
    let (events, _) = a.drain_events();
    assert!(
        events.iter().any(|event| matches!(
            event,
            WorkspaceEvent::Error(message) if message.contains("already exists")
        )),
        "the recaptured inventory rejects the occupied name"
    );
    assert!(
        a.scene
            .runtime
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .get("ssh:studio")
            .expect("remote entry")
            .constructive_cancellation
            .is_none(),
        "the un-launched construction settles its registration"
    );
    assert!(
        !a.scene
            .runtime
            .remote_constructive_in_flight
            .load(Ordering::Acquire)
    );
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one linear proof covering the still-stopped and running outcomes"
)]
fn queued_herdr_restart_revalidates_the_stopped_record_before_launching() {
    let stopped = session::HerdrSessionRecord::new(
        "agents",
        false,
        HerdrSessionState::Stopped,
        "/srv/herdr/agents",
        "/srv/herdr/agents/herdr.sock",
    );
    let running = session::HerdrSessionRecord::new(
        "agents",
        false,
        HerdrSessionState::Running,
        "/srv/herdr/agents",
        "/srv/herdr/agents/herdr.sock",
    );
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let runner = Arc::new(CountingRefusingRunner(AtomicUsize::new(0)));
    let host = counted_remote_host(&config, Arc::clone(&runner));
    let herdr_with = |record: &session::HerdrSessionRecord| HerdrInventory::Available {
        executable: "/usr/bin/herdr".to_owned(),
        sessions: vec![record.clone()],
    };
    let initial = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        7,
        Vec::new(),
        herdr_with(&stopped),
        ZellijInventory::Unavailable,
    );
    let request = RemoteHerdrCreateRequest {
        host_id: config.id().to_owned(),
        connection_generation: 7,
        host: host.clone(),
        snapshot: initial.clone(),
        executable: "/usr/bin/herdr".to_owned(),
        name: HerdrLaunchTarget::discovered(&stopped),
        precondition: HerdrLaunchPrecondition::Stopped(stopped.clone()),
    };
    let a = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let b = a.open_scene();
    let cancellation = CancellationToken::new();
    a.scene.navigation_generation.store(5, Ordering::Release);
    a.scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: Some(host.clone()),
                context: Some(RemoteHostContext {
                    generation: 7,
                    host,
                    snapshot: initial.clone(),
                }),
                cancellation: None,
                constructive_cancellation: Some(RemoteConstructiveState::Active {
                    scene: a.scene.id,
                    navigation_generation: 5,
                    cancellation: cancellation.clone(),
                    launched: Arc::new(AtomicBool::new(false)),
                    target: remote_herdr_target("agents"),
                }),
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );

    // A publication that keeps the record stopped leaves the queued restart
    // launchable: the recapture adopts the newer snapshot.
    let still_stopped = publish_remote_inventory(
        &b.scene,
        "ssh:studio",
        7,
        &initial,
        &CancellationToken::new(),
        RemoteSessionInventory::test_fixture(
            Some("/usr/bin/tmux".to_owned()),
            Vec::new(),
            herdr_with(&stopped),
            ZellijInventory::Unavailable,
        ),
    )
    .expect("scene B publishes inventory with the record still stopped");
    let recaptured = recapture_remote_herdr_create_request(&a.scene.runtime, &request)
        .expect("a still-stopped record keeps the queued restart valid");
    assert_eq!(
        recaptured.snapshot.inventory_generation(),
        still_stopped.inventory_generation()
    );

    // Once the record is running, the production runner's recapture fails
    // the restart closed before issuing any host command. The test holds
    // the operation lane so the runner is queued while the record's state
    // changes; only a post-lane recapture can observe the change.
    let lane = a
        .scene
        .runtime
        .session_operations
        .lock()
        .expect("hold the operation lane");
    let launched = std::thread::scope(|threads| {
        let scene = Arc::clone(&a.scene);
        let runner_cancellation = cancellation.clone();
        let restart = threads.spawn(move || {
            let launched = AtomicBool::new(false);
            run_remote_herdr_create(&scene, &request, 5, &runner_cancellation, &launched);
            launched.load(Ordering::Acquire)
        });
        publish_remote_inventory(
            &b.scene,
            "ssh:studio",
            7,
            &still_stopped,
            &CancellationToken::new(),
            RemoteSessionInventory::test_fixture(
                Some("/usr/bin/tmux".to_owned()),
                Vec::new(),
                herdr_with(&running),
                ZellijInventory::Unavailable,
            ),
        )
        .expect("scene B publishes the running record while the lane is held");
        drop(lane);
        restart.join().expect("the restart completes")
    });

    assert_eq!(
        runner.0.load(Ordering::Acquire),
        0,
        "the rejected restart never reaches the host"
    );
    assert!(!launched);
    let (events, _) = a.drain_events();
    assert!(
        events.iter().any(|event| matches!(
            event,
            WorkspaceEvent::Error(message) if message.contains("already running")
        )),
        "the recaptured inventory rejects the running record"
    );
    assert!(
        a.scene
            .runtime
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .get("ssh:studio")
            .expect("remote entry")
            .constructive_cancellation
            .is_none(),
        "the un-launched restart settles its registration"
    );
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one linear proof that the lane is acquired before the recapture"
)]
fn queued_construction_acquires_the_lane_before_recapturing() {
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let runner = Arc::new(CountingRefusingRunner(AtomicUsize::new(0)));
    let host = counted_remote_host(&config, Arc::clone(&runner));
    // The context inventory already contains the target, so the recapture
    // rejects without host commands once it runs.
    let initial = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        7,
        Vec::new(),
        HerdrInventory::Unavailable,
        ZellijInventory::Available {
            executable: "/usr/bin/zellij".to_owned(),
            sessions: vec![session::ZellijSessionRecord::discovered("review")],
        },
    );
    let request = RemoteZellijCreateRequest {
        host_id: config.id().to_owned(),
        connection_generation: 7,
        host: host.clone(),
        snapshot: initial.clone(),
        executable: "/usr/bin/zellij".to_owned(),
        name: ZellijSessionName::parse("review").expect("valid session name"),
    };
    let a = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let cancellation = CancellationToken::new();
    a.scene.navigation_generation.store(5, Ordering::Release);
    a.scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: Some(host.clone()),
                context: Some(RemoteHostContext {
                    generation: 7,
                    host,
                    snapshot: initial,
                }),
                cancellation: None,
                constructive_cancellation: Some(RemoteConstructiveState::Active {
                    scene: a.scene.id,
                    navigation_generation: 5,
                    cancellation: cancellation.clone(),
                    launched: Arc::new(AtomicBool::new(false)),
                    target: remote_zellij_target("review"),
                }),
                attachment_attempts: Vec::new(),
                generation: 7,
            },
        );

    std::thread::scope(|threads| {
        // Holding the remote-hosts lock parks the recapture's first read.
        // The runner can therefore only be observed holding the operation
        // lane if it acquired the lane BEFORE recapturing; a recapture
        // hoisted above the lane would park here with the lane still free
        // and the probe below would fail loudly.
        let hosts_guard = a
            .scene
            .runtime
            .remote_hosts
            .lock()
            .expect("hold remote hosts");
        let scene = Arc::clone(&a.scene);
        let runner_cancellation = cancellation.clone();
        let construction = threads.spawn(move || {
            run_remote_zellij_create(
                &scene,
                &request,
                5,
                &runner_cancellation,
                &AtomicBool::new(false),
            );
        });
        settle("lane acquisition before the recapture", || {
            matches!(
                a.scene.runtime.session_operations.try_lock(),
                Err(TryLockError::WouldBlock)
            )
        });
        drop(hosts_guard);
        construction.join().expect("the construction completes");
    });

    assert_eq!(
        runner.0.load(Ordering::Acquire),
        0,
        "the occupied target is rejected without host commands"
    );
    let (events, _) = a.drain_events();
    assert!(
        events.iter().any(|event| matches!(
            event,
            WorkspaceEvent::Error(message) if message.contains("already exists")
        )),
        "the post-lane recapture rejects the occupied name"
    );
}

#[cfg(windows)]
#[test]
fn rename_reconciliation_and_attachment_publication_cannot_deadlock() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let original_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "original",
            identity.clone(),
            0,
        )],
    );
    let renamed_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "renamed",
            identity.clone(),
            0,
        )],
    );
    let request = attach_request_fixture(&original_snapshot, identity, "original");
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    *workspace.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: request.host.clone(),
            snapshot: original_snapshot.clone(),
        },
        1,
    ));
    workspace
        .scene
        .attachment
        .lock()
        .expect("attachment")
        .reserve(request.clone(), AttachTerm::Xterm256Color)
        .expect("reserve attachment");

    // One thread models attachment completion: it holds the attachment lock
    // and publishes inventory, which waits on the refresh publication fence.
    // The other reconciles session names for a refresh. If reconciliation
    // took the fence before the attachment lock, these two would block on
    // each other's lock forever; the attachment-first order lets both finish.
    let attachment_held = std::sync::Barrier::new(2);
    let scene = Arc::clone(&workspace.scene);
    std::thread::scope(|threads| {
        let held = &attachment_held;
        let scene_ref = &scene;
        let publish_request = request.clone();
        let publish_snapshot = original_snapshot.clone();
        let publication = threads.spawn(move || {
            let guard = scene_ref.attachment.lock().expect("attachment");
            held.wait();
            // Hold the attachment lock while the reconciler contends for it.
            thread::sleep(Duration::from_millis(50));
            publish_attach_inventory(scene_ref, &publish_request, publish_snapshot);
            drop(guard);
        });
        attachment_held.wait();
        reconcile_presentation_session_names(&workspace.scene.runtime, 0, &renamed_snapshot, None);
        publication
            .join()
            .expect("attachment publication completes");
    });

    assert_eq!(
        workspace
            .scene
            .attachment
            .lock()
            .expect("attachment")
            .active()
            .expect("attachment still reserved")
            .request
            .name,
        "renamed",
        "the rename still lands once the attachment publication releases its lock"
    );
}

#[test]
fn opening_a_scene_concurrent_with_publication_never_leaves_it_stale() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("initial", 0)],
    ));
    let runtime = &workspace.scene.runtime;
    let session_of = |content: &WorkspaceContent| match content {
        WorkspaceContent::Ready { sessions, .. } => sessions[0].name().to_owned(),
        _ => panic!("legacy preview content stays Ready"),
    };
    for round in 0..200_u64 {
        let broadcast = WorkspaceContent::Ready {
            endpoint: "Ubuntu".to_owned(),
            sessions: vec![SessionItem::new(format!("round-{round}"), 0)],
        };
        let start = std::sync::Barrier::new(2);
        let opened = std::thread::scope(|threads| {
            let start_ref = &start;
            let state = broadcast.clone();
            let publisher = threads.spawn(move || {
                start_ref.wait();
                let _write = begin_snapshot_write(runtime);
                publish_legacy_inventory_state(runtime, &state);
            });
            start.wait();
            let opened = workspace.open_scene();
            publisher.join().expect("publisher completes");
            opened
        });
        let store = session_of(
            &runtime
                .inventory_state
                .lock()
                .expect("inventory store")
                .clone(),
        );
        let scene_state = session_of(&opened.scene.state.read().expect("scene content").clone());
        assert_eq!(
            scene_state, store,
            "a scene opened during a publication is never staler than the store"
        );
    }
}

/// Deterministic command runner for lifecycle tests: every command is
/// refused immediately, so background attach and kill workers settle
/// quickly and no real WSL or tmux process is ever spawned.
struct RefusingRunner;

impl CommandRunner for RefusingRunner {
    fn run(
        &self,
        _program: &std::ffi::OsStr,
        _args: &[std::ffi::OsString],
        _cancellation: &CancellationToken,
        _timeout: Duration,
    ) -> std::io::Result<host::CommandOutput> {
        Err(std::io::Error::new(
            std::io::ErrorKind::ConnectionAborted,
            "fixture command refused",
        ))
    }
}

/// Wait until one background lifecycle operation reaches its observable
/// settled outcome.
fn settle(waiting_for: &str, mut done: impl FnMut() -> bool) {
    for _ in 0..400 {
        if done() {
            return;
        }
        thread::sleep(Duration::from_millis(5));
    }
    panic!("background {waiting_for} did not settle");
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one linear proof that real lifecycle operations stay inside their scene"
)]
fn real_lifecycle_operations_in_one_scene_leave_the_other_scene_untouched() {
    let refresh_runtime = Arc::new(ManualRefreshRuntime::default());
    let executable =
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path");
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let a = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(WslHostSpec::available(config.clone(), executable.clone())),
        Arc::new(SystemWslDiscovery::new()),
        refresh_runtime,
    );
    a.scene
        .runtime
        .hosts
        .write()
        .expect("host list")
        .push(HostItem::ssh(
            "ssh:build",
            "build",
            "build.example",
            HostConnectionState::Disconnected,
            Vec::new(),
            None,
        ));
    let host = WslHost::new(
        config,
        Arc::new(RefusingRunner) as SharedCommandRunner,
        executable,
    );
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot",
        42,
        vec![session::DiscoveredSession::new(
            "work",
            session::SessionIdentity::new(100, "$1", 200),
            0,
        )],
    );
    *a.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host,
            snapshot: snapshot.clone(),
        },
        1,
    ));
    set_inventory_state(&a.scene.runtime, &ready_content(&snapshot));

    let b = a.open_scene();
    b.select_host("ssh:build")
        .expect("scene B selects SSH host");
    let b_scene_revision = b.scene.revision.load(Ordering::Acquire);
    let b_before = b.snapshot();

    // Deterministic public lifecycle operations in scene A.
    a.select_host("wsl").expect("scene A selects WSL");
    a.resize(120, 48).expect("scene A resizes its viewer");
    a.detach();
    let (events, _) = a.drain_events();
    assert!(events.is_empty(), "scene A has no pending events");

    // Scene B is untouched: same scene revision, same snapshot revision,
    // same content, selection, notice, and geometry.
    assert_eq!(
        b.scene.revision.load(Ordering::Acquire),
        b_scene_revision,
        "scene A operations never advance scene B's revision counter"
    );
    let b_after = b.snapshot();
    assert_eq!(
        b_after.revision(),
        b_before.revision(),
        "scene A operations never advance scene B's snapshot revision"
    );
    assert!(matches!(b_after.content(), WorkspaceContent::Shell));
    assert_eq!(b_after.selected_host(), Some("ssh:build"));
    assert_eq!(b_after.notice(), None);
    assert_eq!(
        b.scene.terminal_geometry.lock().expect("geometry").sequence,
        0
    );

    // The reverse direction: B's operations leave A's scene revision alone.
    let a_scene_revision = a.scene.revision.load(Ordering::Acquire);
    b.resize(90, 30).expect("scene B resizes its viewer");
    b.detach();
    assert_eq!(
        a.scene.revision.load(Ordering::Acquire),
        a_scene_revision,
        "scene B operations never advance scene A's revision counter"
    );
    assert_eq!(a.snapshot().selected_host(), Some("wsl"));

    // A real attach reservation and a real kill-confirmation request in A,
    // both backed by the refusing command runner so their background
    // workers fail fast and settle observably. The workers touch
    // runtime-scoped state (operation events stay runtime-scoped until the
    // slice-4 pump), so B's isolation is asserted through its scene-local
    // counter and scene-local state.
    let b_scene_revision = b.scene.revision.load(Ordering::Acquire);
    a.attach(&SessionSelection::new("wsl", "Ubuntu", "work"))
        .expect("scene A starts an attachment");
    // The refused attachment settles by clearing its reservation and
    // restoring scene A's inventory content.
    settle("attachment worker", || {
        a.scene
            .attachment
            .lock()
            .expect("scene A attachment")
            .active()
            .is_none()
            && matches!(
                *a.scene.state.read().expect("scene A content"),
                WorkspaceContent::Shell
            )
    });
    let b_snapshot_before_kill = b.snapshot().revision();
    a.request_session_kill(&SessionSelection::new("wsl", "Ubuntu", "work"))
        .expect("scene A requests a kill confirmation");
    // The refused kill preflight settles by reporting its failure as an
    // operation error event.
    settle("kill preflight worker", || {
        let (events, _) = a.drain_events();
        events
            .iter()
            .any(|event| matches!(event, WorkspaceEvent::Error(_)))
    });
    a.cancel_session_kill();
    assert_eq!(
        b.snapshot().revision(),
        b_snapshot_before_kill,
        "scene A's confirmation fencing never re-renders scene B"
    );
    assert_eq!(
        b.scene.revision.load(Ordering::Acquire),
        b_scene_revision,
        "attachment and kill-confirmation flows stay inside scene A"
    );
    let b_final = b.snapshot();
    assert!(matches!(b_final.content(), WorkspaceContent::Shell));
    assert_eq!(b_final.selected_host(), Some("ssh:build"));
    assert_eq!(b_final.notice(), None);
    assert!(
        b_final.revision() >= b_after.revision(),
        "scene B's snapshot revision stays monotonic"
    );
}

#[cfg(windows)]
#[test]
fn superseded_rename_reconciliation_leaves_no_scene_partially_renamed() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let original_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "original",
            identity.clone(),
            0,
        )],
    );
    let renamed_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "renamed",
            identity.clone(),
            0,
        )],
    );
    let request = attach_request_fixture(&original_snapshot, identity, "original");
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    *a.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: request.host.clone(),
            snapshot: original_snapshot.clone(),
        },
        1,
    ));
    let b = a.open_scene();
    for scene in [&a.scene, &b.scene] {
        scene
            .attachment
            .lock()
            .expect("attachment")
            .reserve(request.clone(), AttachTerm::Xterm256Color)
            .expect("reserve attachment");
    }
    let generation = a.scene.runtime.refresh_generation.load(Ordering::Acquire);

    // Scene B's attachment lock is held while a constructive reservation
    // supersedes the publishing refresh, with no successful refresh after
    // it. Reconciliation cannot enter the publication fence until it holds
    // every scene's attachment lock, so by the time it checks the
    // generation the pass is already superseded and no scene — not even
    // scene A, whose lock was free the whole time — may be renamed. A
    // per-scene fence would have renamed scene A before blocking on scene
    // B and left the two scenes permanently inconsistent.
    let scene_b_held = std::sync::Barrier::new(2);
    std::thread::scope(|threads| {
        let held = &scene_b_held;
        let b_scene = Arc::clone(&b.scene);
        let holder = threads.spawn(move || {
            let guard = b_scene.attachment.lock().expect("scene B attachment");
            held.wait();
            held.wait();
            drop(guard);
        });
        scene_b_held.wait();
        let runtime_ref = &a.scene.runtime;
        let renamed_ref = &renamed_snapshot;
        let reconciler = threads.spawn(move || {
            reconcile_presentation_session_names(runtime_ref, generation, renamed_ref, None);
        });
        // Deterministically prove the reconciler holds scene A's attachment
        // lock — and is therefore blocked acquiring scene B's, which the
        // holder thread keeps — before the refresh is superseded. Under a
        // per-scene fence scene A would already be renamed at this point.
        let mut reconciler_holds_scene_a = false;
        for _ in 0..2000 {
            match a.scene.attachment.try_lock() {
                Err(TryLockError::WouldBlock) => {
                    reconciler_holds_scene_a = true;
                    break;
                }
                Ok(free) => drop(free),
                Err(TryLockError::Poisoned(poisoned)) => drop(poisoned.into_inner()),
            }
            thread::sleep(Duration::from_millis(1));
        }
        // Supersede only after the probe confirms the reconciler's position;
        // either way, release the holder and join both threads before any
        // assertion, so a probe failure fails loudly instead of hanging the
        // scope on the parked holder during unwinding.
        if reconciler_holds_scene_a {
            reserve_constructive_inventory(&a.scene.runtime);
        }
        scene_b_held.wait();
        holder.join().expect("scene B lock holder");
        reconciler.join().expect("reconciliation completes");
        assert!(
            reconciler_holds_scene_a,
            "the reconciler never acquired scene A's attachment lock"
        );
    });

    for (label, scene) in [("A", &a.scene), ("B", &b.scene)] {
        assert_eq!(
            scene
                .attachment
                .lock()
                .expect("attachment")
                .active()
                .expect("attachment still reserved")
                .request
                .name,
            "original",
            "scene {label} must not be renamed by a superseded refresh"
        );
    }
}

#[test]
fn joining_scene_waits_out_an_in_flight_publication_and_projects_it() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("initial", 0)],
    ));
    let runtime = &workspace.scene.runtime;
    let (joined_tx, joined_rx) = mpsc::sync_channel(1);

    // Hold the same global snapshot-write gate every publication holds
    // across its store write and revision bump. A join entering now must
    // register and then wait the gate out before projecting, so the
    // interleaving "publication lands while a scene is joining" is forced,
    // not hoped for.
    let publication_gate = begin_snapshot_write(runtime);
    std::thread::scope(|threads| {
        let joining = &workspace;
        threads.spawn(move || {
            joined_tx
                .send(joining.open_scene())
                .expect("deliver joined scene");
        });
        // The join registers before it projects; wait for the registration
        // with a loud deadline so the gate is provably held across its
        // projection window.
        settle("scene registration", || {
            runtime.scenes.lock().expect("scene registry").len() == 2
        });
        // The joining thread has provably reached the wait boundary once
        // its first projection lands: it projects the pre-publication
        // store before checking the gate, and with the gate held its
        // trailing check must fail, so it cannot return until the gate
        // releases.
        let joining_scene = runtime
            .scenes
            .lock()
            .expect("scene registry")
            .iter()
            .find_map(|(_, registered)| {
                registered
                    .upgrade()
                    .filter(|scene| scene.id != workspace.scene.id)
            })
            .expect("the joining scene is registered");
        settle("first projection of the joining scene", || {
            matches!(
                joining_scene.state.read().expect("joining content").clone(),
                WorkspaceContent::Ready { sessions, .. }
                    if sessions.len() == 1 && sessions[0].name() == "initial"
            )
        });
        assert!(
            joined_rx.try_recv().is_err(),
            "join_runtime must not finish while a publication holds the snapshot-write gate"
        );
        publish_legacy_inventory_state(
            runtime,
            &WorkspaceContent::Ready {
                endpoint: "Ubuntu".to_owned(),
                sessions: vec![SessionItem::new("published-during-join", 0)],
            },
        );
        drop(publication_gate);
        let joined = joined_rx
            .recv_timeout(Duration::from_secs(10))
            .expect("join completes once the gate releases");
        assert!(
            matches!(
                joined.scene.state.read().expect("joined content").clone(),
                WorkspaceContent::Ready { sessions, .. }
                    if sessions.len() == 1 && sessions[0].name() == "published-during-join"
            ),
            "the joined scene projects the publication that landed mid-join"
        );
    });
}

#[cfg(windows)]
#[test]
fn constructive_supersession_still_renames_active_presentations() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let original_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "original",
            identity.clone(),
            0,
        )],
    );
    let renamed_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new(
            "renamed",
            identity.clone(),
            0,
        )],
    );
    let request = attach_request_fixture(&original_snapshot, identity, "original");
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    // The refresh's renamed inventory is already published as the
    // authoritative host context.
    *a.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: request.host.clone(),
            snapshot: renamed_snapshot.clone(),
        },
        1,
    ));
    let b = a.open_scene();
    for scene in [&a.scene, &b.scene] {
        scene
            .attachment
            .lock()
            .expect("attachment")
            .reserve(request.clone(), AttachTerm::Xterm256Color)
            .expect("reserve attachment");
    }
    let publishing_generation = a.scene.runtime.refresh_generation.load(Ordering::Acquire);

    // A constructive reservation supersedes the refresh after its
    // inventory was published. The constructive publication reconciles
    // only retained names, so the rename pass must not skip: it retries
    // against the authoritative published snapshot and still renames every
    // scene's active presentation.
    reserve_constructive_inventory(&a.scene.runtime);
    reconcile_presentation_session_names(
        &a.scene.runtime,
        publishing_generation,
        &renamed_snapshot,
        None,
    );

    for (label, scene) in [("A", &a.scene), ("B", &b.scene)] {
        assert_eq!(
            scene
                .attachment
                .lock()
                .expect("attachment")
                .active()
                .expect("attachment still reserved")
                .request
                .name,
            "renamed",
            "scene {label}'s active presentation follows the published rename"
        );
    }
}

#[cfg(windows)]
#[test]
fn pending_confirmation_in_one_scene_survives_other_scene_activity() {
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("work", 0)],
    ));
    let b = a.open_scene();
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new("work", identity.clone(), 0)],
    );
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        Arc::new(RefusingRunner) as SharedCommandRunner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    // Scene A's own kill request below captures against published host
    // authority; the refusing runner settles its preflight with an error.
    *a.scene.runtime.host.lock().expect("published host") = Some(Published::new(
        HostContext {
            host: host.clone(),
            snapshot: snapshot.clone(),
        },
        1,
    ));
    a.scene
        .runtime
        .hosts
        .write()
        .expect("host list")
        .push(HostItem::wsl(
            "Ubuntu",
            None,
            HostConnectionState::Ready,
            vec![SessionItem::new("work", 0)],
            None,
        ));
    a.select_host("wsl").expect("scene A selects WSL");
    // Scene B holds a live kill confirmation minted against its own fence.
    let generation = b.scene.kill_generation.load(Ordering::Acquire);
    assert!(publish_pending_kill(
        &b.scene,
        PendingKill {
            generation,
            selection: SessionSelection::new("wsl", "Ubuntu", "work"),
            host,
            target: KillTarget::Tmux(Arc::new(LiveSessionTarget::test_fixture(
                &snapshot, "work", identity,
            ))),
        },
    ));
    assert!(
        b.session_kill_confirmation().is_some(),
        "scene B holds a live kill confirmation"
    );
    let b_revision = b.snapshot().revision();

    // Scene A navigates: detach advances only scene A's confirmation
    // fences.
    a.detach();
    assert!(
        b.session_kill_confirmation().is_some(),
        "scene A's navigation leaves scene B's confirmation valid"
    );
    assert_eq!(
        b.snapshot().revision(),
        b_revision,
        "scene A's navigation does not re-render scene B"
    );

    // Scene A requests its own kill confirmation and cancels it. The
    // refused preflight settles as an error event inside scene A.
    a.request_session_kill(&SessionSelection::new("wsl", "Ubuntu", "work"))
        .expect("scene A requests its own kill confirmation");
    settle("scene A kill preflight", || {
        let (events, _) = a.drain_events();
        events
            .iter()
            .any(|event| matches!(event, WorkspaceEvent::Error(_)))
    });
    a.cancel_session_kill();

    assert!(
        b.session_kill_confirmation().is_some(),
        "scene A's kill request and cancel leave scene B's confirmation valid"
    );
    assert_eq!(
        b.snapshot().revision(),
        b_revision,
        "scene A's kill request and cancel do not re-render scene B"
    );

    // Scene B's confirmation is still confirmable: the confirm passes B's
    // fence and starts the kill task, which the refusing runner settles as
    // an error event inside scene B.
    b.confirm_session_kill()
        .expect("scene B's confirmation is still current after scene A's activity");
    settle("scene B kill task", || {
        let (events, _) = b.drain_events();
        events
            .iter()
            .any(|event| matches!(event, WorkspaceEvent::Error(_)))
    });
}

#[cfg(windows)]
#[test]
fn pump_handles_a_worker_exit_without_any_scene_drain() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new("work", identity.clone(), 0)],
    );
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    set_inventory_state(&workspace.scene.runtime, &ready_content(&snapshot));
    set_scene_state(&workspace.scene, WorkspaceContent::Loading);

    let request = attach_request_fixture(&snapshot, identity.clone(), "work");
    let generation = workspace
        .scene
        .attachment
        .lock()
        .expect("attachment")
        .reserve(request, AttachTerm::Xterm256Color)
        .expect("reserve the attachment slot");
    let plan = session::AttachPlan::attach_only(
        "cmd.exe",
        ["/d", "/c", "exit 0"]
            .into_iter()
            .map(std::ffi::OsString::from)
            .collect(),
        "work",
        identity,
    );
    let worker = TerminalWorker::attach(&plan, GridSize::new(40, 4).expect("valid grid"))
        .expect("attach ConPTY client");
    let worker_generation = workspace
        .scene
        .worker
        .lock()
        .expect("worker")
        .publish(worker);

    // The pump alone — no scene ever calls drain_events — observes the
    // exit, invalidates the worker and attachment, and restores the scene
    // to published inventory.
    settle("pump-driven worker exit", || {
        let _backlog = pump_once(&workspace.scene.runtime);
        workspace
            .scene
            .worker
            .lock()
            .expect("worker")
            .active()
            .is_none()
    });
    assert!(
        workspace.scene.worker.lock().expect("worker").generation() > worker_generation,
        "the exited worker generation is invalidated"
    );
    assert!(
        !workspace
            .scene
            .attachment
            .lock()
            .expect("attachment")
            .is_current(generation),
        "a clean exit releases the attachment slot"
    );
    assert!(
        matches!(
            &*workspace.scene.state.read().expect("scene state"),
            WorkspaceContent::Ready { endpoint, .. } if endpoint == "Ubuntu"
        ),
        "the pump restores published inventory without a drain"
    );
}

fn created_worktree_target() -> KwtWorktreeTarget {
    KwtWorktreeTarget {
        host_id: "wsl".to_owned(),
        endpoint: "Ubuntu".to_owned(),
        repository: "github.com/acme/widget".to_owned(),
        project_path: "/code/widget".to_owned(),
        registration_fingerprint: "registration".to_owned(),
        worktree_path: "/work/widget/topic".to_owned(),
        generation: Some("0123456789abcdef0123456789abcdef".to_owned()),
        session_name: "widget-topic".to_owned(),
        tmux_socket_name: None,
    }
}

#[test]
fn broadcast_facts_reach_every_scene_without_consuming_each_other() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let b = a.open_scene();
    let a_revision = a.scene.revision.load(Ordering::Acquire);
    let b_revision = b.scene.revision.load(Ordering::Acquire);

    let target = created_worktree_target();
    broadcast_event(&a.scene.runtime, || WorkspaceEvent::KwtWorktreeCreated {
        target: target.clone(),
        navigation_generation: 41,
    });

    let (a_events, a_more) = a.drain_events();
    assert!(
        matches!(
            a_events.as_slice(),
            [WorkspaceEvent::KwtWorktreeCreated { .. }]
        ),
        "the initiating side observes the broadcast fact"
    );
    assert!(!a_more);
    let (b_events, _) = b.drain_events();
    assert!(
        matches!(
            b_events.as_slice(),
            [WorkspaceEvent::KwtWorktreeCreated { .. }]
        ),
        "draining scene A never consumes scene B's copy"
    );
    assert!(
        a.scene.revision.load(Ordering::Acquire) > a_revision
            && b.scene.revision.load(Ordering::Acquire) > b_revision,
        "a broadcast advances each receiving scene's revision as it enqueues"
    );
}

#[test]
fn broadcast_created_fact_never_matches_another_scenes_navigation_intent() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let b = a.open_scene();

    // Navigation generations are runtime-minted from one shared sequence:
    // two scenes can never draw the same value, so a broadcast fact carrying
    // the initiator's generation can never read as another scene's own
    // pending operation.
    let a_generation = a.begin_navigation();
    let b_generation = b.begin_navigation();
    assert_ne!(
        a_generation, b_generation,
        "navigation generations are unique across scenes"
    );

    let target = created_worktree_target();
    broadcast_event(&a.scene.runtime, || WorkspaceEvent::KwtWorktreeCreated {
        target: target.clone(),
        navigation_generation: a_generation,
    });

    let (b_events, _) = b.drain_events();
    let foreign_generation = match b_events.as_slice() {
        [
            WorkspaceEvent::KwtWorktreeCreated {
                navigation_generation,
                ..
            },
        ] => *navigation_generation,
        other => panic!(
            "scene B receives exactly the broadcast fact, got {} events",
            other.len()
        ),
    };
    assert!(
        !b.navigation_intent_is_current(foreign_generation),
        "the foreign generation never reads as scene B's current intent"
    );
    assert!(
        a.navigation_intent_is_current(a_generation),
        "the initiating scene still owns its intent"
    );
}

#[test]
fn clipboard_writes_from_a_pass_that_predates_a_purge_are_dropped() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    // A pump pass captures the epoch before extracting worker events.
    let observed = workspace.scene.clipboard_epoch.load(Ordering::Acquire);

    // A retirement lands between the pass's extraction and its flush.
    crate::scene::purge_queued_clipboard_writes(&workspace.scene);

    // The pass's deferred clipboard push observes the moved epoch and drops.
    crate::scene::push_clipboard_write_event(
        &workspace.scene,
        WorkspaceEvent::ClipboardWrite {
            text: "extracted before the purge".to_owned(),
            primary: false,
        },
        observed,
    );
    let (events, _) = workspace.drain_events();
    assert!(
        events.is_empty(),
        "a clipboard write extracted before a purge never lands after it"
    );

    // A pass that starts after the retirement delivers normally.
    let current = workspace.scene.clipboard_epoch.load(Ordering::Acquire);
    crate::scene::push_clipboard_write_event(
        &workspace.scene,
        WorkspaceEvent::ClipboardWrite {
            text: "extracted after the purge".to_owned(),
            primary: false,
        },
        current,
    );
    let (events, _) = workspace.drain_events();
    assert!(
        matches!(
            events.as_slice(),
            [WorkspaceEvent::ClipboardWrite { text, .. }] if text == "extracted after the purge"
        ),
        "writes extracted at the current epoch still deliver"
    );
}

#[test]
fn retiring_clipboard_writes_purges_queued_writes_but_nothing_else() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    push_lossless_event(
        &workspace.scene,
        WorkspaceEvent::ClipboardWrite {
            text: "stale write".to_owned(),
            primary: false,
        },
    );
    push_lossless_event(
        &workspace.scene,
        WorkspaceEvent::Error("survives the purge".to_owned()),
    );

    crate::scene::purge_queued_clipboard_writes(&workspace.scene);

    let (events, _) = workspace.drain_events();
    assert!(
        matches!(
            events.as_slice(),
            [WorkspaceEvent::Error(message)] if message == "survives the purge"
        ),
        "a queued clipboard write emitted for a presentation that stopped          being visible is dropped, while unrelated queued events survive"
    );
}

#[test]
fn editing_a_host_id_repoints_other_scenes_at_the_renamed_host() {
    let initiator = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![
            HostItem::ssh(
                "host-a",
                "Host A",
                "wes@a",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
            HostItem::ssh(
                "host-b",
                "Host B",
                "wes@b",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
        ],
    ));
    let other = initiator.open_scene();
    other.select_host("host-a").expect("select host in scene B");

    // The edit path removes the original id with the renamed id as its
    // successor; selections follow the rename, not an arbitrary survivor.
    let navigation = lock_live_navigation(&initiator.scene).expect("scene is live");
    initiator.remove_ssh_host_runtime(&navigation, "host-a", Some("host-a-renamed"));
    drop(navigation);

    assert_eq!(
        other
            .scene
            .selected_host
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_deref(),
        Some("host-a-renamed"),
        "another scene's selection follows the renamed host"
    );
}

#[test]
fn inventory_cadence_survives_its_initiating_scene_and_clears_when_none_remain() {
    let refresh = Arc::new(ManualRefreshRuntime::default());
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let spec = WslHostSpec::available(
        config,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let initiator = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        Arc::new(SystemWslDiscovery::new()),
        refresh.clone(),
    );
    initiator
        .start_inventory_cadence()
        .expect("start inventory cadence");
    assert_eq!(refresh.deadline_delays().len(), 1, "one scheduled tick");

    let survivor = initiator.open_scene();
    let runtime = Arc::clone(&survivor.scene.runtime);
    drop(initiator);

    // The tick fired after the initiating scene closed re-anchors on the
    // surviving scene and reschedules; the cadence stays started.
    refresh.run_next_deadline();
    assert_eq!(
        refresh.deadline_delays().len(),
        1,
        "the cadence reschedules anchored on the surviving scene"
    );
    assert!(
        runtime.inventory_cadence_started.load(Ordering::Acquire),
        "the started flag stays set while a scene lives"
    );

    drop(survivor);

    // With no scenes left the tick clears the started flag and stops, so a
    // future scene's startup gate restarts the cadence.
    refresh.run_next_deadline();
    assert_eq!(
        refresh.deadline_delays().len(),
        0,
        "no further tick is scheduled once every scene closed"
    );
    assert!(
        !runtime.inventory_cadence_started.load(Ordering::Acquire),
        "the started flag clears so a future scene restarts the cadence"
    );
}

#[test]
fn kwt_cadence_survives_its_initiating_scene_and_clears_when_none_remain() {
    let refresh = Arc::new(ManualRefreshRuntime::default());
    let bundle =
        host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
    let config = WslConfig::with_distro("Ubuntu")
        .expect("valid config")
        .with_kwt_bundle(bundle);
    let spec = WslHostSpec::available(
        config,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let initiator = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        Arc::new(SystemWslDiscovery::new()),
        refresh.clone(),
    );
    initiator
        .start_inventory_cadence()
        .expect("start both cadences");
    assert_eq!(
        refresh.deadline_delays().len(),
        2,
        "inventory and KWT ticks are both scheduled"
    );

    let survivor = initiator.open_scene();
    let runtime = Arc::clone(&survivor.scene.runtime);
    drop(initiator);

    refresh.run_next_deadline();
    refresh.run_next_deadline();
    assert_eq!(
        refresh.deadline_delays().len(),
        2,
        "both cadences reschedule anchored on the surviving scene"
    );
    assert!(
        runtime.kwt_cadence_started.load(Ordering::Acquire),
        "the KWT started flag stays set while a scene lives"
    );

    drop(survivor);

    refresh.run_next_deadline();
    refresh.run_next_deadline();
    assert_eq!(
        refresh.deadline_delays().len(),
        0,
        "no cadence reschedules once every scene closed"
    );
    assert!(
        !runtime.kwt_cadence_started.load(Ordering::Acquire),
        "the KWT started flag clears so a future scene restarts the cadence"
    );
    assert!(
        !runtime.inventory_cadence_started.load(Ordering::Acquire),
        "the inventory started flag clears alongside it"
    );
}

#[cfg(windows)]
#[test]
fn removing_a_host_drops_other_scenes_retained_presentations() {
    let initiator = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let other = initiator.open_scene();
    let identity = session::SessionIdentity::new(42, "$1", 100);
    let snapshot = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        8,
        vec![session::DiscoveredSession::new("work", identity.clone(), 0)],
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );
    other
        .scene
        .remote_retained
        .lock()
        .expect("remote retained")
        .entries
        .push(RemoteRetainedPresentation {
            active: RemoteActive {
                key: RemotePresentationKey {
                    host_id: "ssh:studio".to_owned(),
                    endpoint: "studio.example".to_owned(),
                    route_identity: TEST_REMOTE_ROUTE.to_owned(),
                    lease_generation: 8,
                    session_identity: RemoteSessionIdentity::Tmux(identity.clone()),
                },
                selection: SessionSelection::new("ssh:studio", "studio.example", "work"),
                worker_generation: 98,
                lease: snapshot.lease().clone(),
                presentation_id: 43,
                term: AttachTerm::Xterm256Color,
                retainable: true,
                identity_mismatch_marker: None,
            },
            worker: conpty_keepalive_worker("remote-retained", identity.clone()),
        });

    // The non-initiating scene also presents the doomed host actively.
    *other.scene.remote_active.lock().expect("remote active") = Some(RemoteActive {
        key: RemotePresentationKey {
            host_id: "ssh:studio".to_owned(),
            endpoint: "studio.example".to_owned(),
            route_identity: TEST_REMOTE_ROUTE.to_owned(),
            lease_generation: 8,
            session_identity: RemoteSessionIdentity::Tmux(identity.clone()),
        },
        selection: SessionSelection::new("ssh:studio", "studio.example", "work"),
        worker_generation: 99,
        lease: snapshot.lease().clone(),
        presentation_id: 44,
        term: AttachTerm::Xterm256Color,
        retainable: true,
        identity_mismatch_marker: None,
    });

    let navigation = lock_live_navigation(&initiator.scene).expect("scene is live");
    initiator.remove_ssh_host_runtime(&navigation, "ssh:studio", None);
    drop(navigation);

    assert!(
        other
            .scene
            .remote_active
            .lock()
            .expect("remote active")
            .is_none(),
        "a non-initiating scene's active presentation on the removed host \
         is detached"
    );
    assert!(
        !other
            .scene
            .remote_retained
            .lock()
            .expect("remote retained")
            .has_workers(),
        "a non-initiating scene's retained presentations for the removed \
         host are dropped"
    );
}

#[test]
fn refresh_and_discovery_refuse_a_closed_scene() {
    let refresh = Arc::new(ManualRefreshRuntime::default());
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let spec = WslHostSpec::available(
        config,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let initiator = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        Arc::new(SystemWslDiscovery::new()),
        refresh.clone(),
    );
    let survivor = initiator.open_scene();
    initiator.close();

    let error = initiator
        .refresh()
        .expect_err("a closed scene initiates no shared refresh");
    assert!(
        error.to_string().contains("closed"),
        "the refresh fence names the closed scene: {error}"
    );
    let error = initiator
        .connect_enabled_hosts()
        .expect_err("a closed scene initiates no startup discovery");
    assert!(
        error.to_string().contains("closed"),
        "the discovery fence names the closed scene: {error}"
    );
    assert!(
        refresh.deadline_delays().is_empty(),
        "no host work was scheduled on behalf of the closed scene"
    );

    // A live scene still refreshes through the same entry point.
    survivor
        .refresh()
        .expect("a surviving scene refreshes normally");
}

#[test]
fn removing_the_initiating_scenes_own_host_detaches_under_the_held_fence() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let identity = session::SessionIdentity::new(42, "$1", 100);
    let snapshot = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        8,
        vec![session::DiscoveredSession::new("work", identity.clone(), 0)],
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );
    *workspace.scene.remote_active.lock().expect("remote active") = Some(RemoteActive {
        key: RemotePresentationKey {
            host_id: "ssh:studio".to_owned(),
            endpoint: "studio.example".to_owned(),
            route_identity: TEST_REMOTE_ROUTE.to_owned(),
            lease_generation: 8,
            session_identity: RemoteSessionIdentity::Tmux(identity),
        },
        selection: SessionSelection::new("ssh:studio", "studio.example", "work"),
        worker_generation: 99,
        lease: snapshot.lease().clone(),
        presentation_id: 44,
        term: AttachTerm::Xterm256Color,
        retainable: true,
        identity_mismatch_marker: None,
    });

    // Hold the fence exactly as the public remove/edit paths do; the
    // removal loop reaching this scene's own active presentation must
    // detach without re-locking the non-reentrant navigation mutex.
    {
        let navigation = lock_live_navigation(&workspace.scene).expect("scene is live");
        workspace.remove_ssh_host_runtime(&navigation, "ssh:studio", None);
    }

    assert!(
        workspace
            .scene
            .remote_active
            .lock()
            .expect("remote active")
            .is_none(),
        "the initiating scene's own presentation on the removed host detaches"
    );
}

#[test]
fn connect_never_holds_navigation_while_waiting_on_publication() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let host = remote_host_fixture(&config);
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: Some(host),
                context: None,
                cancellation: None,
                constructive_cancellation: None,
                attachment_attempts: Vec::new(),
                generation: 8,
            },
        );

    // Reproduce the deadlock interleaving the review flagged: one side
    // holds the publication lock and reconciles (taking every scene's
    // navigation lock), while a connect runs concurrently. Before the
    // lock-order fix the connect held its scene's navigation lock while
    // waiting on publication, wedging the reconciliation forever.
    let publication = workspace
        .scene
        .runtime
        .remote_publication
        .lock()
        .expect("publication lock");
    let connecting = Workspace {
        scene: Arc::clone(&workspace.scene),
    };
    let (done, finished) = std::sync::mpsc::channel();
    let joiner = thread::spawn(move || {
        let _ = connecting.connect_host("ssh:studio");
        let _ = done.send(());
    });
    // Give the connect time to reach its first lock acquisition.
    thread::sleep(Duration::from_millis(150));
    // The reconciliation runs bounded on its own thread: a regressed lock
    // order (connect holding navigation while waiting on publication)
    // fails this test as a clean timeout instead of hanging the suite
    // inside the reconciliation.
    let reconcile_runtime = Arc::clone(&workspace.scene.runtime);
    let (reconcile_done, reconcile_finished) = std::sync::mpsc::channel();
    let reconciler = thread::spawn(move || {
        let _stale = reconcile_remote_presentations(
            &reconcile_runtime,
            "ssh:studio",
            "studio.example",
            TEST_REMOTE_ROUTE,
            8,
            None,
        );
        let _ = reconcile_done.send(());
    });
    reconcile_finished
        .recv_timeout(Duration::from_secs(10))
        .expect("the publication-held reconciliation never blocks on a connect");
    reconciler.join().expect("reconcile thread exits");
    drop(publication);
    finished
        .recv_timeout(Duration::from_secs(10))
        .expect("the connect completes once publication releases");
    joiner.join().expect("connect thread exits");
}

#[test]
fn completion_refresh_reanchors_on_a_surviving_scene() {
    let refresh = Arc::new(ManualRefreshRuntime::default());
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let spec = WslHostSpec::available(
        config,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let initiator = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        Arc::new(SystemWslDiscovery::new()),
        refresh,
    );
    let survivor = initiator.open_scene();
    initiator.close();

    initiator
        .refresh_reanchored()
        .expect("a completed mutation's refresh re-anchors on the survivor");

    survivor.close();
    let error = initiator
        .refresh_reanchored()
        .expect_err("with every scene closed there is nothing to re-anchor on");
    assert!(error.to_string().contains("closed"), "{error}");
}

#[test]
fn cancellations_are_rejected_from_a_closed_scene() {
    // Real in-flight work is armed on both cancel paths — a Connecting
    // WSL host guards the shared refresh, and a live remote cancellation
    // token guards the host connection — so deleting either closed-scene
    // fence makes a cancel succeed and fail these assertions.
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![
            HostItem::wsl(
                "Ubuntu",
                None,
                HostConnectionState::Connecting,
                Vec::new(),
                None,
            ),
            HostItem::ssh(
                "ssh:studio",
                "Studio",
                "studio.example",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
        ],
    ));
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "",
        None,
    )
    .expect("valid remote host");
    let token = CancellationToken::new();
    workspace
        .scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: None,
                context: None,
                cancellation: Some(token.clone()),
                constructive_cancellation: None,
                attachment_attempts: Vec::new(),
                generation: 3,
            },
        );
    let refresh_generation = workspace
        .scene
        .runtime
        .refresh_generation
        .load(Ordering::Acquire);
    workspace.close();

    assert!(
        !workspace.cancel_refresh(),
        "a closed scene cancels no shared refresh"
    );
    assert_eq!(
        workspace
            .scene
            .runtime
            .refresh_generation
            .load(Ordering::Acquire),
        refresh_generation,
        "the armed refresh's fence is untouched"
    );
    assert!(
        !workspace.cancel_host_connection("ssh:studio"),
        "a closed scene cancels no host connection"
    );
    assert!(
        !token.is_cancelled(),
        "the live connection's token stays uncancelled"
    );
    let hosts = workspace
        .scene
        .runtime
        .hosts
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    assert!(
        hosts
            .iter()
            .any(|host| host.id == "wsl" && host.connection == HostConnectionState::Connecting),
        "the armed refresh's host stays Connecting"
    );
    assert!(
        hosts
            .iter()
            .any(|host| host.id == "ssh:studio" && host.connection == HostConnectionState::Ready),
        "the rejected cancellation published no disconnected state"
    );
}

#[test]
fn destructive_lifecycle_paths_refuse_a_closed_scene() {
    let refresh = Arc::new(ManualRefreshRuntime::default());
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let spec = WslHostSpec::available(
        config,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let workspace = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        Arc::new(SystemWslDiscovery::new()),
        refresh.clone(),
    );
    let selection = SessionSelection::new("wsl", "Ubuntu", "work");
    workspace.close();

    let error = workspace
        .request_session_kill(&selection)
        .expect_err("a closed scene arms no kill confirmation");
    assert!(error.to_string().contains("closed"), "{error}");
    let error = workspace
        .confirm_session_kill()
        .expect_err("a closed scene confirms no kill");
    assert!(error.to_string().contains("closed"), "{error}");
    let error = workspace
        .request_herdr_lifecycle(&selection, HerdrLifecycleAction::Stop)
        .expect_err("a closed scene arms no Herdr lifecycle action");
    assert!(error.to_string().contains("closed"), "{error}");
    let error = workspace
        .confirm_herdr_lifecycle()
        .expect_err("a closed scene confirms no Herdr lifecycle action");
    assert!(error.to_string().contains("closed"), "{error}");

    let error = workspace
        .approve_paste()
        .expect_err("a closed scene approves no paste");
    assert!(error.to_string().contains("closed"), "{error}");
    let error = workspace
        .request_kwt_worktree_removal(
            "wsl",
            "Ubuntu",
            "wes/ghosthub",
            "/home/wes/ghosthub",
            "fp",
            "/home/wes/ghosthub-web",
            &"a".repeat(40),
            "ghosthub/web",
            None,
        )
        .expect_err("a closed scene arms no worktree removal");
    assert!(error.to_string().contains("closed"), "{error}");
    assert!(
        workspace
            .scene
            .kwt_removal_capture_intent
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_none(),
        "the refused request wrote no capture intent — the slot it arms synchronously, unlike the asynchronously published authority"
    );

    // The refused requests armed nothing: the pending slots the confirm
    // paths would execute from stay empty, observed directly rather than
    // through a queue these paths never use.
    assert!(
        workspace.session_kill_confirmation().is_none(),
        "no kill confirmation was armed for the closed scene"
    );
    assert!(
        workspace.herdr_lifecycle_confirmation().is_none(),
        "no Herdr lifecycle confirmation was armed for the closed scene"
    );
    assert!(
        refresh.deadline_delays().is_empty(),
        "no deadline work was scheduled by the refused paths"
    );
}

#[test]
fn settings_mutations_refuse_a_closed_scene() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let survivor = workspace.open_scene();
    workspace.close();

    let error = workspace
        .save_appearance(&AppearanceSettingsDraft {
            theme: TerminalTheme::Custom,
            font_family: "monospace".to_owned(),
            font_size: "14".to_owned(),
            background: "#101010".to_owned(),
            foreground: "#e0e0e0".to_owned(),
        })
        .expect_err("a closed scene saves no appearance");
    assert!(error.to_string().contains("closed"), "{error}");

    let error = workspace
        .save_ssh_host(
            None,
            &SshHostDraft {
                name: "Host".to_owned(),
                hostname: "host.example".to_owned(),
                user: String::new(),
                port: String::new(),
                tmux_binary: "tmux".to_owned(),
                socket_directory: String::new(),
            },
        )
        .expect_err("a closed scene saves no SSH host");
    assert!(error.to_string().contains("closed"), "{error}");

    let error = workspace
        .remove_ssh_host("host-a")
        .expect_err("a closed scene removes no SSH host");
    assert!(error.to_string().contains("closed"), "{error}");

    // The surviving scene's runtime state is untouched by the refusals.
    assert!(
        survivor
            .scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_empty(),
        "no host state appeared on behalf of the closed scene"
    );
}

#[test]
fn connect_host_refuses_a_closed_scene() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "host-a",
            "Host A",
            "wes@a",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    workspace.close();

    let error = workspace
        .connect_host("host-a")
        .expect_err("a closed scene starts no host connection");
    assert!(
        error.to_string().contains("closed"),
        "the close fence names the closed scene: {error}"
    );
}

#[test]
fn cadence_stops_for_a_closed_scene_held_by_a_retained_handle() {
    let refresh = Arc::new(ManualRefreshRuntime::default());
    let config = WslConfig::with_distro("Ubuntu").expect("valid config");
    let spec = WslHostSpec::available(
        config,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let initiator = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        Arc::new(SystemWslDiscovery::new()),
        refresh.clone(),
    );
    initiator
        .start_inventory_cadence()
        .expect("start inventory cadence");
    assert_eq!(refresh.deadline_delays().len(), 1);

    // Explicit close while the handle stays alive: the weak upgrade still
    // succeeds, but a closed scene must never anchor the cadence.
    initiator.close();
    refresh.run_next_deadline();

    assert_eq!(
        refresh.deadline_delays().len(),
        0,
        "a closed scene held by a retained handle does not keep the \
         cadence running"
    );
    assert!(
        !initiator
            .scene
            .runtime
            .inventory_cadence_started
            .load(Ordering::Acquire),
        "the started flag clears so a future scene restarts the cadence"
    );
}

#[test]
fn kwt_cadence_stops_for_a_closed_scene_held_by_a_retained_handle() {
    let refresh = Arc::new(ManualRefreshRuntime::default());
    let bundle =
        host::KwtBundle::new("a".repeat(40), "b".repeat(64), [1_u8]).expect("valid bundle");
    let config = WslConfig::with_distro("Ubuntu")
        .expect("valid config")
        .with_kwt_bundle(bundle);
    let spec = WslHostSpec::available(
        config,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );
    let initiator = Workspace::application_with_services(
        TerminalAppearance::default(),
        Some(spec),
        Arc::new(SystemWslDiscovery::new()),
        refresh.clone(),
    );
    initiator
        .start_inventory_cadence()
        .expect("start both cadences");
    assert_eq!(refresh.deadline_delays().len(), 2);

    initiator.close();
    refresh.run_next_deadline();
    refresh.run_next_deadline();

    assert_eq!(
        refresh.deadline_delays().len(),
        0,
        "neither cadence reschedules for a closed scene held by a retained handle"
    );
    assert!(
        !initiator
            .scene
            .runtime
            .kwt_cadence_started
            .load(Ordering::Acquire),
        "the KWT started flag clears so a future scene restarts the cadence"
    );
}

#[test]
fn inventory_polling_is_wanted_while_any_live_scene_enables_it() {
    let first = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let second = first.open_scene();
    assert!(
        !crate::scene::inventory_polling_wanted(&first.scene.runtime),
        "no scene has enabled polling yet"
    );

    second.set_inventory_polling_enabled(true);
    assert!(
        crate::scene::inventory_polling_wanted(&first.scene.runtime),
        "one enabled scene keeps the cadence polling"
    );

    first.set_inventory_polling_enabled(false);
    assert!(
        crate::scene::inventory_polling_wanted(&first.scene.runtime),
        "another scene disabling its own polling does not pause the \
         enabled scene"
    );

    second.close();
    assert!(
        !crate::scene::inventory_polling_wanted(&first.scene.runtime),
        "a closed scene's enablement no longer counts"
    );
}

#[test]
fn kwt_operations_refuse_a_closed_scene() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    workspace.close();

    let error = workspace
        .add_kwt_project("wsl", "Ubuntu", "/home/wes/project")
        .expect_err("a closed scene starts no KWT project mutation");
    assert!(
        error.to_string().contains("closed"),
        "the close fence names the closed scene: {error}"
    );
    let error = workspace
        .load_kwt_branches("wsl", "Ubuntu", "wes/ghosthub", "/home/wes/ghosthub", "fp")
        .expect_err("a closed scene starts no KWT worktree operation");
    assert!(
        error.to_string().contains("closed"),
        "the worktree-operation fence names the closed scene: {error}"
    );
    assert!(
        !workspace
            .scene
            .runtime
            .kwt_mutation_in_flight
            .load(Ordering::Acquire),
        "a refused reservation leaves the shared KWT lane free"
    );
}

#[test]
fn kwt_listing_ownership_is_scene_scoped() {
    let owner = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let other = owner.open_scene();
    owner
        .scene
        .runtime
        .kwt_refresh_generation
        .store(7, Ordering::Release);
    *owner
        .scene
        .runtime
        .kwt_worktree_listing
        .lock()
        .expect("listing slot") = Some(KwtWorktreeListing {
        generation: 7,
        operation_id: 21,
        scene_id: owner.scene.id,
        cancellation: CancellationToken::new(),
    });

    assert!(
        !other.cancel_kwt_worktree_listing(21),
        "another scene presenting the operation id cannot cancel the \
         owner's listing"
    );
    assert!(
        owner
            .scene
            .runtime
            .kwt_worktree_listing
            .lock()
            .expect("listing slot")
            .is_some(),
        "the listing survives the foreign cancellation attempt"
    );

    owner.close();

    assert!(
        owner
            .scene
            .runtime
            .kwt_worktree_listing
            .lock()
            .expect("listing slot")
            .is_none(),
        "closing the owner cancels its listing and frees the slot"
    );
    assert!(
        !owner
            .scene
            .runtime
            .kwt_mutation_in_flight
            .load(Ordering::Acquire),
        "closing the owner releases the shared KWT lane"
    );
    assert_eq!(
        owner
            .scene
            .runtime
            .kwt_refresh_generation
            .load(Ordering::Acquire),
        8,
        "the close bumps the publication generation past the cancelled listing so a late task completion cannot settle"
    );
}

#[test]
fn concurrent_settings_mutations_from_two_scenes_serialize() {
    // The removal loop is the one path holding one scene's navigation
    // lock while acquiring others'; the settings mutation lock, taken
    // before each caller's fence, is what keeps two such invocations from
    // deadlocking. This drives both with the production lock sequence
    // behind timeouts, so losing that serialization panics cleanly.
    let first = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![
            HostItem::ssh(
                "host-a",
                "Host A",
                "wes@a",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
            HostItem::ssh(
                "host-b",
                "Host B",
                "wes@b",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
        ],
    ));
    let second = first.open_scene();

    let mut removers = Vec::new();
    let first_handle = Workspace {
        scene: Arc::clone(&first.scene),
    };
    let second_handle = Workspace {
        scene: Arc::clone(&second.scene),
    };
    for (workspace, doomed) in [(first_handle, "host-a"), (second_handle, "host-b")] {
        let (done, finished) = std::sync::mpsc::channel();
        removers.push((
            thread::spawn(move || {
                let _mutation = workspace
                    .scene
                    .runtime
                    .settings_mutation
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let navigation = lock_live_navigation(&workspace.scene).expect("scene is live");
                workspace.remove_ssh_host_runtime(&navigation, doomed, None);
                drop(navigation);
                let _ = done.send(());
            }),
            finished,
        ));
    }
    for (joiner, finished) in removers {
        finished
            .recv_timeout(Duration::from_secs(10))
            .expect("serialized settings mutations never deadlock across scenes");
        joiner.join().expect("removal thread exits");
    }
    assert!(
        first
            .scene
            .runtime
            .hosts
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_empty(),
        "both removals completed"
    );
}

#[test]
fn closure_during_a_retry_launch_suppresses_the_failure_publication() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let (entered_sender, entered) = mpsc::sync_channel(1);
    let (release_sender, release) = mpsc::channel();
    let runner = Arc::new(BlockingRestoreRunner {
        entered: Mutex::new(Some(entered_sender)),
        release: Mutex::new(release),
    });
    let request = attach_request_fixture_with_runner(
        &snapshot,
        identity,
        "work",
        runner as SharedCommandRunner,
    );
    let retry = RetainedRetry {
        key: request.presentation_key(),
        request,
    };
    workspace
        .scene
        .retained_presentations
        .lock()
        .expect("retained presentations")
        .restarting
        .push(RetainedRestart {
            key: retry.key.clone(),
            selection: retry.request.selection(),
            attachment: ActiveAttachment {
                request: retry.request.clone(),
                term: AttachTerm::Xterm,
                generation: 1,
                fallback: None,
            },
            presentation_id: 7,
        });

    let scene = Arc::clone(&workspace.scene);
    let (done, finished) = std::sync::mpsc::channel();
    let running = thread::spawn(move || {
        crate::scene::run_retained_retry(&scene, &retry);
        let _ = done.send(());
    });
    entered
        .recv_timeout(Duration::from_secs(10))
        .expect("the retry reached its unfenced discovery");

    // Closure wins mid-launch; the released discovery then fails, and the
    // post-launch fence must swallow the failure instead of pushing a
    // notice into the dead scene. The blocked runner fails the first
    // command, so this drives the Host error arm; the SessionChanged arm
    // (whose publication mutates runtime-wide inventory) is guarded only
    // transitively, by the fence sitting at the shared dispatch point
    // before the match — a refactor that pushes the closed-check into the
    // individual arms must add a direct SessionChanged drive, which needs
    // a fake runner producing a full successful WSL discovery.
    workspace.close();
    let revision_after_close = workspace.scene.revision.load(Ordering::Acquire);
    release_sender.send(()).expect("release the discovery");
    finished
        .recv_timeout(Duration::from_secs(10))
        .expect("the retry completes after release");
    running.join().expect("retry thread exits");

    assert!(
        workspace
            .scene
            .terminal_notice
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_none(),
        "the mid-launch failure raises no notice in the dead scene"
    );
    assert_eq!(
        workspace.scene.revision.load(Ordering::Acquire),
        revision_after_close,
        "the mid-launch failure publishes nothing after closure"
    );
}

#[test]
fn retained_retries_never_hold_navigation_while_waiting_on_operations() {
    // Mimic a remote attach: hold session_operations, then acquire the
    // scene's navigation lock — the ops-then-nav order every remote path
    // uses. A concurrent retained retry must use the same order; the
    // reverse (nav held, parked on ops) wedges both threads. Timeouts turn
    // a reintroduced inversion into a clean panic.
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let request = attach_request_fixture(&snapshot, identity, "work");
    let retry = RetainedRetry {
        key: request.presentation_key(),
        request,
    };
    workspace
        .scene
        .retained_presentations
        .lock()
        .expect("retained presentations")
        .restarting
        .push(RetainedRestart {
            key: retry.key.clone(),
            selection: retry.request.selection(),
            attachment: ActiveAttachment {
                request: retry.request.clone(),
                term: AttachTerm::Xterm,
                generation: 1,
                fallback: None,
            },
            presentation_id: 7,
        });

    let operations = workspace
        .scene
        .runtime
        .session_operations
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);

    let scene = Arc::clone(&workspace.scene);
    let (done, finished) = std::sync::mpsc::channel();
    let runner = thread::spawn(move || {
        crate::scene::run_retained_retry(&scene, &retry);
        let _ = done.send(());
    });
    thread::sleep(Duration::from_millis(100));

    // The remote-attach side: with ops held, navigation must be free —
    // a retry that grabbed navigation before parking on ops would wedge
    // this acquisition forever.
    let (nav_done, nav_finished) = std::sync::mpsc::channel();
    let nav_scene = Arc::clone(&workspace.scene);
    let nav_thread = thread::spawn(move || {
        let guard = nav_scene
            .navigation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        drop(guard);
        let _ = nav_done.send(());
    });
    nav_finished
        .recv_timeout(Duration::from_secs(10))
        .expect("navigation stays free while a retry waits on operations");
    nav_thread.join().expect("navigation thread exits");

    // Close before releasing operations so the parked retry observes the
    // closed fence and returns without a real launch — the completion is
    // deterministic instead of depending on a live attach. The close runs
    // behind its own timeout: in a regressed nav-first world the retry
    // holds navigation while parked on operations, and release_scene's
    // navigation acquisition would wedge this thread forever.
    let close_scene = Arc::clone(&workspace.scene);
    let (close_done, close_finished) = std::sync::mpsc::channel();
    let closer = thread::spawn(move || {
        let handle = Workspace { scene: close_scene };
        handle.close();
        let _ = close_done.send(());
    });
    close_finished
        .recv_timeout(Duration::from_secs(10))
        .expect("closure never wedges behind a retry's held navigation");
    closer.join().expect("close thread exits");
    drop(operations);
    finished
        .recv_timeout(Duration::from_secs(10))
        .expect("the retry completes once operations releases");
    runner.join().expect("retry thread exits");
}

#[cfg(windows)]
#[test]
fn a_clipboard_response_never_reaches_a_successor_worker() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let identity = session::SessionIdentity::new(42, "$1", 100);
    let worker = conpty_keepalive_worker("clipboard", identity);
    let generation = {
        let mut workers = workspace
            .scene
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        workers.publish(worker)
    };
    let request = ClipboardRead {
        inner: terminal::ClipboardReadRequest::test_fixture(),
        worker_generation: generation.wrapping_sub(1),
    };

    // The stale request mimics navigation retiring the originating worker
    // between extraction and delivery: the response is refused instead of
    // being typed into the successor session.
    let error = workspace
        .complete_clipboard_read(&request, "secret")
        .expect_err("a response bound to a retired worker is refused");
    assert!(error.to_string().contains("closed terminal"), "{error}");
    assert!(
        error.is_stale_input(),
        "the refusal is marked stale so the UI drops only this entry"
    );

    let current = ClipboardRead {
        inner: terminal::ClipboardReadRequest::test_fixture(),
        worker_generation: generation,
    };
    workspace
        .complete_clipboard_read(&current, "secret")
        .expect("the originating worker still receives its response");
}

#[test]
fn a_retained_retry_extracted_before_closure_never_launches() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let runner = Arc::new(CountingRefusingRunner(AtomicUsize::new(0)));
    let request = attach_request_fixture_with_runner(
        &snapshot,
        identity,
        "work",
        Arc::clone(&runner) as SharedCommandRunner,
    );
    let retry = RetainedRetry {
        key: request.presentation_key(),
        request,
    };
    workspace
        .scene
        .retained_presentations
        .lock()
        .expect("retained presentations")
        .restarting
        .push(RetainedRestart {
            key: retry.key.clone(),
            selection: retry.request.selection(),
            attachment: ActiveAttachment {
                request: retry.request.clone(),
                term: AttachTerm::Xterm,
                generation: 1,
                fallback: None,
            },
            presentation_id: 7,
        });
    workspace.close();

    // The launch itself is the observable: the injected runner counts
    // every executed command, so zero commands proves the pre-launch
    // fence returned before any launch machinery — regardless of what
    // the post-launch fence suppresses. Revision and notice stay as
    // secondary checks on the publication side.
    let revision_before = workspace.scene.revision.load(Ordering::Acquire);
    crate::scene::run_retained_retry(&workspace.scene, &retry);
    assert_eq!(
        runner.0.load(Ordering::Acquire),
        0,
        "a closed scene's retry executes no host command"
    );
    assert_eq!(
        workspace.scene.revision.load(Ordering::Acquire),
        revision_before,
        "a closed scene's retry publishes nothing"
    );
    assert!(
        workspace
            .scene
            .terminal_notice
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_none(),
        "a closed scene's retry raises no terminal notice"
    );
}

#[test]
fn removal_waits_for_a_scenes_navigation_before_judging_its_presentation() {
    let initiator = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![
            HostItem::ssh(
                "ssh:studio",
                "Studio",
                "studio.example",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
            HostItem::ssh(
                "host-b",
                "Host B",
                "wes@b",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
        ],
    ));
    let other = initiator.open_scene();
    let identity = session::SessionIdentity::new(42, "$1", 100);
    let snapshot = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        8,
        vec![session::DiscoveredSession::new("work", identity.clone(), 0)],
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );

    // A session switch is in flight on the other scene: its navigation
    // lock is held while its presentation lands on the doomed host. The
    // removal must wait for that lock before judging the scene, so the
    // just-landed presentation is seen and detached — pre-fix the
    // unguarded check ran mid-switch, saw nothing, and left the removed
    // host's client alive.
    let switch_guard = other
        .scene
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);

    let remover = Workspace {
        scene: Arc::clone(&initiator.scene),
    };
    let (done, finished) = std::sync::mpsc::channel();
    let removal = thread::spawn(move || {
        let navigation = lock_live_navigation(&remover.scene).expect("scene is live");
        remover.remove_ssh_host_runtime(&navigation, "ssh:studio", None);
        drop(navigation);
        let _ = done.send(());
    });
    thread::sleep(Duration::from_millis(150));

    *other.scene.remote_active.lock().expect("remote active") = Some(RemoteActive {
        key: RemotePresentationKey {
            host_id: "ssh:studio".to_owned(),
            endpoint: "studio.example".to_owned(),
            route_identity: TEST_REMOTE_ROUTE.to_owned(),
            lease_generation: 8,
            session_identity: RemoteSessionIdentity::Tmux(identity),
        },
        selection: SessionSelection::new("ssh:studio", "studio.example", "work"),
        worker_generation: 99,
        lease: snapshot.lease().clone(),
        presentation_id: 44,
        term: AttachTerm::Xterm256Color,
        retainable: true,
        identity_mismatch_marker: None,
    });
    assert!(
        finished.try_recv().is_err(),
        "the removal is still blocked on the held navigation lock"
    );
    drop(switch_guard);

    finished
        .recv_timeout(Duration::from_secs(10))
        .expect("the removal completes once the switch releases its lock");
    removal.join().expect("removal thread exits");

    assert!(
        other
            .scene
            .remote_active
            .lock()
            .expect("remote active")
            .is_none(),
        "the presentation that landed on the doomed host mid-switch is \
         detached, never left alive past the removal"
    );
}

#[test]
fn a_concurrent_surviving_selection_is_never_overwritten_by_removal() {
    // In every legal interleaving the survivor selection wins: landing
    // before the removal's compare leaves it untouched, landing after
    // overrides the fallback. Only the removed compare-then-write gap
    // could let the fallback overwrite it; iterate to widen detection.
    for _ in 0..40 {
        let initiator = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![
                HostItem::ssh(
                    "host-a",
                    "Host A",
                    "wes@a",
                    HostConnectionState::Ready,
                    Vec::new(),
                    None,
                ),
                HostItem::ssh(
                    "host-b",
                    "Host B",
                    "wes@b",
                    HostConnectionState::Ready,
                    Vec::new(),
                    None,
                ),
                HostItem::ssh(
                    "host-c",
                    "Host C",
                    "wes@c",
                    HostConnectionState::Ready,
                    Vec::new(),
                    None,
                ),
            ],
        ));
        initiator.select_host("host-a").expect("select doomed host");
        let selector = Workspace {
            scene: Arc::clone(&initiator.scene),
        };
        let selecting = thread::spawn(move || {
            selector
                .select_host("host-c")
                .expect("select surviving host");
        });

        let navigation = lock_live_navigation(&initiator.scene).expect("scene is live");
        initiator.remove_ssh_host_runtime(&navigation, "host-a", None);
        drop(navigation);
        selecting.join().expect("selector thread exits");

        assert_eq!(
            initiator
                .scene
                .selected_host
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_deref(),
            Some("host-c"),
            "the concurrently selected surviving host stays selected"
        );
    }
}

#[test]
fn a_concurrent_surviving_selection_is_never_overwritten_by_rename() {
    for _ in 0..40 {
        let initiator = Workspace::preview(WorkspaceSnapshot::shell(
            Appearance::default(),
            vec![
                HostItem::ssh(
                    "host-a",
                    "Host A",
                    "wes@a",
                    HostConnectionState::Ready,
                    Vec::new(),
                    None,
                ),
                HostItem::ssh(
                    "host-c",
                    "Host C",
                    "wes@c",
                    HostConnectionState::Ready,
                    Vec::new(),
                    None,
                ),
            ],
        ));
        initiator
            .select_host("host-a")
            .expect("select original host");
        let edited = SshHostSettings::new("Renamed", "renamed.example", None, None, "", None)
            .expect("valid settings");
        let selector = Workspace {
            scene: Arc::clone(&initiator.scene),
        };
        let selecting = thread::spawn(move || {
            selector
                .select_host("host-c")
                .expect("select surviving host");
        });

        let navigation = lock_live_navigation(&initiator.scene).expect("scene is live");
        initiator
            .publish_saved_ssh_host(&navigation, Some("host-a"), &edited)
            .expect("publish the rename");
        drop(navigation);
        selecting.join().expect("selector thread exits");

        let selected = initiator
            .scene
            .selected_host
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        assert_eq!(
            selected.as_deref(),
            Some("host-c"),
            "the concurrently selected surviving host survives the rename"
        );
    }
}

#[test]
fn a_selection_never_survives_a_concurrent_host_removal() {
    let initiator = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![
            HostItem::ssh(
                "host-a",
                "Host A",
                "wes@a",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
            HostItem::ssh(
                "host-b",
                "Host B",
                "wes@b",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
        ],
    ));
    let selector = Workspace {
        scene: Arc::clone(&initiator.scene),
    };
    let done = Arc::new(AtomicBool::new(false));
    let selector_done = Arc::clone(&done);
    // Hammer the selection while the removal runs: post-fix the selection
    // write happens under the host-list read guard, so it serializes
    // against the removal's list write — the removal's reconciliation
    // either sees the selection and re-points it, or the late select
    // fails on the missing host. Pre-fix a select could recheck, lose the
    // guard, and write the removed host after reconciliation had passed.
    let selecting = thread::spawn(move || {
        while !selector_done.load(Ordering::Acquire) {
            let _ = selector.select_host("host-a");
        }
    });
    thread::sleep(Duration::from_millis(20));

    let navigation = lock_live_navigation(&initiator.scene).expect("scene is live");
    initiator.remove_ssh_host_runtime(&navigation, "host-a", None);
    drop(navigation);
    done.store(true, Ordering::Release);
    selecting.join().expect("selector thread exits");

    assert_ne!(
        initiator
            .scene
            .selected_host
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_deref(),
        Some("host-a"),
        "no interleaving leaves the selection naming the removed host \
         after the removal returned"
    );
}

#[test]
fn removing_a_host_reconciles_every_live_scene() {
    let initiator = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![
            HostItem::ssh(
                "host-a",
                "Host A",
                "wes@a",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
            HostItem::ssh(
                "host-b",
                "Host B",
                "wes@b",
                HostConnectionState::Ready,
                Vec::new(),
                None,
            ),
        ],
    ));
    let other = initiator.open_scene();
    other.select_host("host-a").expect("select host in scene B");
    let other_revision = other.scene.revision.load(Ordering::Acquire);

    let navigation = lock_live_navigation(&initiator.scene).expect("scene is live");
    initiator.remove_ssh_host_runtime(&navigation, "host-a", None);
    drop(navigation);

    assert_eq!(
        other
            .scene
            .selected_host
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_deref(),
        Some("host-b"),
        "a scene that did not initiate the removal still moves its          selection off the removed host"
    );
    assert!(
        other.scene.revision.load(Ordering::Acquire) > other_revision,
        "the reconciled scene's revision advances so its client repolls"
    );
}

#[test]
fn addressed_events_reach_exactly_the_initiating_scene() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let b = a.open_scene();
    let b_revision = b.scene.revision.load(Ordering::Acquire);

    push_operation_event(
        &a.scene,
        WorkspaceEvent::Error("scene A operation".to_owned()),
    );

    let (b_events, _) = b.drain_events();
    assert!(
        b_events.is_empty(),
        "an addressed event never appears in another scene's inbox"
    );
    assert_eq!(
        b.scene.revision.load(Ordering::Acquire),
        b_revision,
        "an addressed event never advances another scene's revision"
    );
    let (a_events, _) = a.drain_events();
    assert!(
        matches!(
            a_events.as_slice(),
            [WorkspaceEvent::Error(message)] if message == "scene A operation"
        ),
        "the initiating scene observes its addressed event"
    );
}

#[test]
fn concurrent_scene_drains_never_steal_each_others_events() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let b = a.open_scene();
    for index in 0..24 {
        push_operation_event(&a.scene, WorkspaceEvent::Error(format!("a-{index}")));
        push_operation_event(&b.scene, WorkspaceEvent::Error(format!("b-{index}")));
    }

    let drain_all = |workspace: Workspace| {
        move || {
            let mut collected = Vec::new();
            loop {
                let (events, more) = workspace.drain_events();
                collected.extend(events.into_iter().map(|event| match event {
                    WorkspaceEvent::Error(message) => message,
                    _ => panic!("only errors were enqueued"),
                }));
                if !more {
                    break collected;
                }
            }
        }
    };
    let a_thread = thread::spawn(drain_all(a.clone()));
    let b_thread = thread::spawn(drain_all(b.clone()));
    let a_drained = a_thread.join().expect("scene A drain");
    let b_drained = b_thread.join().expect("scene B drain");

    let expected = |prefix: &str| -> Vec<String> {
        (0..24).map(|index| format!("{prefix}-{index}")).collect()
    };
    assert_eq!(a_drained, expected("a"), "scene A drains exactly its FIFO");
    assert_eq!(b_drained, expected("b"), "scene B drains exactly its FIFO");
}

#[test]
fn overflowing_inbox_cancels_a_dropped_prompt_and_keeps_fifo_survivors() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let (sender, receiver) = sync_channel(1);
    push_operation_event(
        &workspace.scene,
        WorkspaceEvent::SshPrompt(SshPromptRequest {
            host_id: "ssh:studio".to_owned(),
            generation: 7,
            prompt: host::SshLeasePrompt::test_fixture(),
            response: Arc::new(Mutex::new(Some(sender))),
        }),
    );
    for index in 0..SCENE_INBOX_LIMIT - 1 {
        push_operation_event(
            &workspace.scene,
            WorkspaceEvent::Error(format!("filler-{index}")),
        );
    }
    assert_eq!(
        receiver.try_recv(),
        Err(std::sync::mpsc::TryRecvError::Empty),
        "a queued prompt inside the bound stays unanswered"
    );

    push_operation_event(
        &workspace.scene,
        WorkspaceEvent::Error(format!("filler-{}", SCENE_INBOX_LIMIT - 1)),
    );

    assert_eq!(
        receiver.try_recv(),
        Ok(None),
        "the dropped addressed request is cancelled, never silently discarded"
    );
    let mut drained = Vec::new();
    loop {
        let (events, more) = workspace.drain_events();
        drained.extend(events);
        if !more {
            break;
        }
    }
    assert_eq!(drained.len(), SCENE_INBOX_LIMIT, "the bound holds");
    assert!(
        matches!(&drained[0], WorkspaceEvent::Error(message) if message == "filler-0"),
        "survivors keep FIFO order after the shed"
    );
}

#[test]
fn overflowing_inbox_denies_a_dropped_paste_confirmation() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    *workspace.scene.pending_paste.lock().expect("pending paste") = Some(PendingPaste {
        worker_generation: 7,
        input: input::encode_input(
            &KeyInput::paste("withheld\ninput"),
            input::TerminalModes::default(),
        ),
    });
    push_operation_event(&workspace.scene, WorkspaceEvent::ConfirmPaste);
    for index in 0..SCENE_INBOX_LIMIT {
        push_operation_event(
            &workspace.scene,
            WorkspaceEvent::Error(format!("filler-{index}")),
        );
    }
    assert!(
        workspace
            .scene
            .pending_paste
            .lock()
            .expect("pending paste")
            .is_none(),
        "dropping the confirmation request denies the withheld paste"
    );
}

#[cfg(windows)]
#[test]
fn shed_paste_confirmation_sends_the_worker_cancel_and_resumes_input() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    set_inventory_state(&workspace.scene.runtime, &ready_content(&snapshot));
    let plan = session::AttachPlan::attach_only(
        "cmd.exe",
        ["/d", "/q", "/k", "prompt", "pump$G"]
            .into_iter()
            .map(std::ffi::OsString::from)
            .collect(),
        "work",
        identity,
    );
    let worker = TerminalWorker::attach(&plan, GridSize::new(80, 8).expect("valid grid"))
        .expect("attach ConPTY client");
    // A multi-line paste requires confirmation: the worker suspends command
    // intake and reports ConfirmPaste.
    worker
        .send_key(KeyInput::paste("echo first\r\necho second"))
        .expect("queue guarded paste");
    // Input queued while suspended: it can only reach the child after the
    // worker receives the paste verdict.
    worker
        .send_key(KeyInput::text(
            "echo resumed-after-deny",
            Modifiers::default(),
        ))
        .expect("queue follow-up text");
    worker
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .expect("queue follow-up enter");
    let _generation = workspace
        .scene
        .worker
        .lock()
        .expect("worker")
        .publish(worker);

    settle("pump observes the paste confirmation", || {
        let _backlog = pump_once(&workspace.scene.runtime);
        workspace
            .scene
            .pending_paste
            .lock()
            .expect("pending paste")
            .is_some()
    });

    // Shed a confirmation request through inbox overflow: the eviction must
    // deny the withheld paste AT THE WORKER, not merely clear the slot.
    push_operation_event(&workspace.scene, WorkspaceEvent::ConfirmPaste);
    for index in 0..SCENE_INBOX_LIMIT {
        push_operation_event(
            &workspace.scene,
            WorkspaceEvent::Error(format!("filler-{index}")),
        );
    }
    assert!(
        workspace
            .scene
            .pending_paste
            .lock()
            .expect("pending paste")
            .is_none(),
        "the shed confirmation denies the withheld paste"
    );
    settle("worker resumes command intake after the deny", || {
        let worker = workspace.scene.worker.lock().expect("worker");
        let Some(worker) = worker.active() else {
            return false;
        };
        let surface = worker.surface().load();
        let text = surface.cells().map(surface::Cell::text).collect::<String>();
        text.contains("resumed-after-deny")
    });
}

#[cfg(windows)]
#[test]
fn full_inbox_pauses_only_that_scenes_worker_pumping_and_loses_nothing() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new("work", identity.clone(), 0)],
    );
    let exiting_worker = |name: &str| {
        let plan = session::AttachPlan::attach_only(
            "cmd.exe",
            ["/d", "/c", "exit 0"]
                .into_iter()
                .map(std::ffi::OsString::from)
                .collect(),
            name,
            identity.clone(),
        );
        TerminalWorker::attach(&plan, GridSize::new(40, 4).expect("valid grid"))
            .expect("attach ConPTY client")
    };

    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    set_inventory_state(&a.scene.runtime, &ready_content(&snapshot));
    let b = a.open_scene();
    for (workspace, name) in [(&a, "work-a"), (&b, "work-b")] {
        set_scene_state(&workspace.scene, WorkspaceContent::Loading);
        workspace
            .scene
            .attachment
            .lock()
            .expect("attachment")
            .reserve(
                attach_request_fixture(&snapshot, identity.clone(), name),
                AttachTerm::Xterm256Color,
            )
            .expect("reserve the attachment slot");
        let _generation = workspace
            .scene
            .worker
            .lock()
            .expect("worker")
            .publish(exiting_worker(name));
    }
    // Scene A's inbox has no headroom for a pump pass; scene B's does.
    for index in 0..SCENE_INBOX_LIMIT {
        push_operation_event(&a.scene, WorkspaceEvent::Error(format!("filler-{index}")));
    }

    settle("scene B's exit is handled while scene A is paused", || {
        let _backlog = pump_once(&a.scene.runtime);
        b.scene
            .worker
            .lock()
            .expect("scene B worker")
            .active()
            .is_none()
    });
    assert!(
        a.scene
            .worker
            .lock()
            .expect("scene A worker")
            .active()
            .is_some(),
        "a full inbox pauses that scene's worker pumping"
    );
    assert!(
        pump_once(&a.scene.runtime),
        "a paused scene with a live worker reports backlog"
    );

    // Draining scene A restores headroom without losing a single event.
    let mut drained = Vec::new();
    loop {
        let (events, more) = a.drain_events();
        drained.extend(events);
        if !more {
            break;
        }
    }
    assert_eq!(
        drained.len(),
        SCENE_INBOX_LIMIT,
        "backpressure sheds nothing while the scene is paused"
    );
    settle("scene A's exit is handled after the drain", || {
        let _backlog = pump_once(&a.scene.runtime);
        a.scene
            .worker
            .lock()
            .expect("scene A worker")
            .active()
            .is_none()
    });
    assert!(
        matches!(
            &*a.scene.state.read().expect("scene A state"),
            WorkspaceContent::Ready { .. }
        ),
        "the resumed pump completes exit handling"
    );
}

#[test]
fn overflow_evicts_the_oldest_sheddable_entry_never_a_lossless_one() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    // Lossless entries sit at the FRONT of the queue: a plain pop_front
    // regression would evict these instead of the oldest sheddable entry.
    push_lossless_event(
        &workspace.scene,
        WorkspaceEvent::Error("lossless-0".to_owned()),
    );
    push_lossless_event(
        &workspace.scene,
        WorkspaceEvent::Error("lossless-1".to_owned()),
    );
    // The oldest SHEDDABLE entry is an addressed request whose capability
    // must observe the cancellation when it is shed.
    let (sender, receiver) = sync_channel(1);
    push_operation_event(
        &workspace.scene,
        WorkspaceEvent::SshPrompt(SshPromptRequest {
            host_id: "ssh:studio".to_owned(),
            generation: 7,
            prompt: host::SshLeasePrompt::test_fixture(),
            response: Arc::new(Mutex::new(Some(sender))),
        }),
    );
    for index in 0..SCENE_INBOX_LIMIT - 3 {
        push_operation_event(
            &workspace.scene,
            WorkspaceEvent::Error(format!("op-{index}")),
        );
    }
    assert_eq!(
        receiver.try_recv(),
        Err(std::sync::mpsc::TryRecvError::Empty),
        "nothing is shed while the inbox is at its bound"
    );

    // Overflow: the eviction must skip the lossless front and shed the
    // prompt — the oldest sheddable entry — cancelling it.
    push_operation_event(
        &workspace.scene,
        WorkspaceEvent::Error("op-overflow".to_owned()),
    );
    assert_eq!(
        receiver.try_recv(),
        Ok(None),
        "the oldest sheddable entry is shed and cancelled"
    );

    let mut drained = Vec::new();
    loop {
        let (events, more) = workspace.drain_events();
        drained.extend(events.into_iter().map(|event| match event {
            WorkspaceEvent::Error(message) => message,
            WorkspaceEvent::SshPrompt(_) => panic!("the shed prompt cannot still be queued"),
            _ => panic!("only errors and the prompt were enqueued"),
        }));
        if !more {
            break;
        }
    }
    assert_eq!(drained.len(), SCENE_INBOX_LIMIT, "the bound holds");
    assert_eq!(
        &drained[..2],
        ["lossless-0", "lossless-1"],
        "the lossless front survives in FIFO order"
    );
    assert_eq!(drained[2], "op-0", "survivors keep FIFO order");
    assert_eq!(
        drained.last().map(String::as_str),
        Some("op-overflow"),
        "the overflowing push itself is queued"
    );
}

#[test]
fn kwt_mutation_outcome_survives_a_flooded_inbox_and_reaches_drain() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    for index in 0..SCENE_INBOX_LIMIT {
        push_operation_event(
            &workspace.scene,
            WorkspaceEvent::Error(format!("flood-{index}")),
        );
    }
    // The dialog-settling outcome arrives while the inbox is already full,
    // and enough sheddable noise lands after it that a wrongly-sheddable
    // outcome would provably be evicted: every sheddable entry that
    // preceded it is displaced twice over.
    push_lossless_event(
        &workspace.scene,
        WorkspaceEvent::KwtProjectMutationFinished {
            action: KwtProjectAction::Add,
        },
    );
    for index in 0..2 * SCENE_INBOX_LIMIT {
        push_operation_event(
            &workspace.scene,
            WorkspaceEvent::Error(format!("late-{index}")),
        );
    }

    // Direct inbox inspection before any drain: the settlement is still
    // queued as the sole non-sheddable entry — overflow removed only
    // sheddable entries around it.
    {
        let inbox = workspace
            .scene
            .operation_events
            .lock()
            .expect("scene inbox");
        let lossless: Vec<_> = inbox.iter().filter(|entry| !entry.sheddable).collect();
        assert_eq!(lossless.len(), 1, "only sheddable entries were evicted");
        assert!(
            matches!(
                lossless[0].event,
                WorkspaceEvent::KwtProjectMutationFinished { .. }
            ),
            "the surviving non-sheddable entry is the settlement"
        );
    }

    let mut outcomes = 0;
    loop {
        let (events, more) = workspace.drain_events();
        outcomes += events
            .iter()
            .filter(|event| matches!(event, WorkspaceEvent::KwtProjectMutationFinished { .. }))
            .count();
        if !more {
            break;
        }
    }
    assert_eq!(
        outcomes, 1,
        "the dialog-settling outcome survives the flood and reaches drain"
    );
}

#[test]
fn created_fact_is_lossless_only_for_the_initiating_scene() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let b = a.open_scene();
    for index in 0..SCENE_INBOX_LIMIT {
        push_operation_event(&a.scene, WorkspaceEvent::Error(format!("a-flood-{index}")));
        push_operation_event(&b.scene, WorkspaceEvent::Error(format!("b-flood-{index}")));
    }

    let target = created_worktree_target();
    broadcast_event_with_lossless_owner(&a.scene.runtime, a.scene.id, || {
        WorkspaceEvent::KwtWorktreeCreated {
            target: target.clone(),
            navigation_generation: 41,
        }
    });
    for index in 0..2 * SCENE_INBOX_LIMIT {
        push_operation_event(&a.scene, WorkspaceEvent::Error(format!("a-late-{index}")));
        push_operation_event(&b.scene, WorkspaceEvent::Error(format!("b-late-{index}")));
    }

    let count_created = |workspace: &Workspace| {
        let mut created = 0;
        loop {
            let (events, more) = workspace.drain_events();
            created += events
                .iter()
                .filter(|event| matches!(event, WorkspaceEvent::KwtWorktreeCreated { .. }))
                .count();
            if !more {
                break created;
            }
        }
    };
    assert_eq!(
        count_created(&a),
        1,
        "the initiating scene's dialog-settling copy survives the flood"
    );
    assert_eq!(
        count_created(&b),
        0,
        "another scene's informational copy remains sheddable"
    );
}

#[test]
fn creation_expiry_settles_the_owning_scene_even_when_another_scene_resolves() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let b = a.open_scene();
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let now = Instant::now();
    a.scene
        .runtime
        .pending_kwt_creations
        .lock()
        .expect("pending creations")
        .push(PendingKwtCreation {
            scene: a.scene.id,
            endpoint: snapshot.endpoint().clone(),
            repository: "github.com/acme/widget".to_owned(),
            project_path: "/code/widget".to_owned(),
            registration_fingerprint: "registration".to_owned(),
            branch: "feature/new".to_owned(),
            navigation_generation: 44,
            baseline: Vec::new(),
            refreshes_remaining: PENDING_KWT_CREATION_REFRESH_LIMIT,
            deadline: now,
        });
    let inventory = KwtInventory::parse(b"[]", b"[]", b"[]").expect("valid empty KWT inventory");

    // Scene B's refresh resolves the expiry of scene A's pending creation.
    resolve_pending_kwt_creations_at(&b.scene, snapshot.endpoint(), &inventory, now);

    let (b_events, _) = b.drain_events();
    assert!(
        b_events.is_empty(),
        "the resolving scene does not receive the owner's settlement"
    );
    let (a_events, _) = a.drain_events();
    assert!(
        matches!(
            a_events.as_slice(),
            [WorkspaceEvent::KwtWorktreeCreationExpired {
                navigation_generation: 44,
                ..
            }]
        ),
        "the expiry settles the owning scene's dialog"
    );
}

/// Block on an SSH prompt for one scene exactly as `connect_host`'s spawned
/// task does: the closure captures the initiating scene and calls
/// `request_ssh_prompt`, so this is the connect task's blocked prompt loop.
fn spawn_prompt(
    workspace: &Workspace,
    generation: u64,
) -> thread::JoinHandle<Result<String, host::SshError>> {
    let scene = Arc::clone(&workspace.scene);
    let cancellation = CancellationToken::new();
    thread::spawn(move || {
        request_ssh_prompt(
            &scene,
            "ssh:studio",
            generation,
            &host::SshLeasePrompt::test_fixture(),
            &cancellation,
        )
    })
}

fn drain_ssh_prompt(workspace: &Workspace) -> Option<SshPromptRequest> {
    let (events, _) = workspace.drain_events();
    events.into_iter().find_map(|event| match event {
        WorkspaceEvent::SshPrompt(request) => Some(request),
        _ => None,
    })
}

#[test]
fn ssh_prompt_reaches_only_the_initiating_scene() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let b = a.open_scene();

    let connect = spawn_prompt(&a, 7);
    let mut request = None;
    settle("SSH prompt delivery to the initiating scene", || {
        request = drain_ssh_prompt(&a);
        request.is_some()
    });
    let request = request.expect("scene A's request");
    assert_eq!(request.generation(), 7);
    assert!(
        b.drain_events().0.is_empty(),
        "the addressed request never reaches another scene"
    );

    request.respond(Some("hunter2".to_owned()));
    assert_eq!(
        connect
            .join()
            .expect("connect task")
            .expect("the answered prompt resolves the connect"),
        "hunter2"
    );
    let mut dismissed = false;
    settle("SSH prompt dismissal delivery", || {
        dismissed |= a.drain_events().0.iter().any(|event| {
            matches!(
                event,
                WorkspaceEvent::SshPromptDismissed { generation: 7, .. }
            )
        });
        dismissed
    });
    assert!(
        b.drain_events().0.is_empty(),
        "the dismissal is addressed to the initiating scene only"
    );
}

#[test]
fn closing_the_initiating_scene_mid_prompt_fails_the_connect_closed() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let b = a.open_scene();
    let b_revision = b.snapshot().revision();

    let connect = spawn_prompt(&a, 7);
    settle("SSH prompt lands in the initiating scene's inbox", || {
        a.scene
            .operation_events
            .lock()
            .expect("scene A inbox")
            .iter()
            .any(|entry| matches!(entry.event, WorkspaceEvent::SshPrompt(_)))
    });

    a.close();

    let error = connect
        .join()
        .expect("connect task")
        .expect_err("scene close fails the blocked connect");
    assert_eq!(
        error.to_string(),
        host::SshError::prompt_cancelled().to_string(),
        "the connect fails with the established prompt-cancelled error"
    );
    assert!(
        a.scene
            .operation_events
            .lock()
            .expect("scene A inbox")
            .is_empty(),
        "the closed scene's inbox drained through cancellation"
    );
    assert!(
        live_scenes(&b.scene.runtime)
            .iter()
            .all(|scene| scene.id != a.scene.id),
        "the closed scene is unregistered"
    );
    assert_eq!(
        b.snapshot().revision(),
        b_revision,
        "another scene's revision is untouched by the close"
    );
    assert!(
        b.drain_events().0.is_empty(),
        "the request was never reassigned to another scene"
    );

    // Another scene may explicitly retry the connect from the beginning; the
    // retry mints a fresh request addressed to itself.
    let retry = spawn_prompt(&b, 8);
    let mut request = None;
    settle("scene B's own fresh prompt", || {
        request = drain_ssh_prompt(&b);
        request.is_some()
    });
    let request = request.expect("scene B's request");
    assert_eq!(request.generation(), 8, "the retry is a fresh request");
    request.respond(Some("fresh".to_owned()));
    assert_eq!(
        retry
            .join()
            .expect("retry task")
            .expect("scene B's own prompt is answerable"),
        "fresh"
    );
}

#[test]
fn scene_close_after_prompt_delivery_kills_the_capability() {
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let b = a.open_scene();

    let connect = spawn_prompt(&a, 7);
    let mut request = None;
    settle("SSH prompt delivery before the close", || {
        request = drain_ssh_prompt(&a);
        request.is_some()
    });
    let request = request.expect("the drained request");

    // The client drained the request, then its scene closed before
    // answering: the blocked connect observes the close and fails.
    a.close();
    let error = connect
        .join()
        .expect("connect task")
        .expect_err("the blocked prompt loop observes the close");
    assert_eq!(
        error.to_string(),
        host::SshError::prompt_cancelled().to_string()
    );

    // The capability is dead: late responses are no-ops and revive nothing.
    request.respond(Some("late".to_owned()));
    request.respond(Some("later".to_owned()));
    assert!(
        b.drain_events().0.is_empty(),
        "scene B is untouched throughout"
    );
}

#[cfg(windows)]
#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one linear proof that a closed scene releases every held resource"
)]
fn closing_a_scene_releases_worker_presentations_attempts_and_lease() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let host_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new("work", identity.clone(), 0)],
    );
    let a = Workspace::preview(WorkspaceSnapshot::shell(
        Appearance::default(),
        vec![HostItem::ssh(
            "ssh:studio",
            "Studio",
            "studio.example",
            HostConnectionState::Ready,
            Vec::new(),
            None,
        )],
    ));
    set_inventory_state(&a.scene.runtime, &ready_content(&host_snapshot));
    let b = a.open_scene();

    // A live local worker holding scene B's reserved attachment slot.
    set_scene_state(&b.scene, WorkspaceContent::Loading);
    b.scene
        .attachment
        .lock()
        .expect("attachment")
        .reserve(
            attach_request_fixture(&host_snapshot, identity.clone(), "work"),
            AttachTerm::Xterm256Color,
        )
        .expect("reserve the attachment slot");
    let plan = session::AttachPlan::attach_only(
        "cmd.exe",
        ["/d", "/q", "/k", "prompt", "close$G"]
            .into_iter()
            .map(std::ffi::OsString::from)
            .collect(),
        "work",
        identity.clone(),
    );
    let worker = TerminalWorker::attach(&plan, GridSize::new(40, 4).expect("valid grid"))
        .expect("attach ConPTY client");
    let _generation = b.scene.worker.lock().expect("worker").publish(worker);

    // A connected remote entry, scene B's registered attach attempt on it,
    // and a remote presentation holding a lease clone in scene B.
    let config = RemoteTmuxConfig::new(
        "ssh:studio",
        "Studio",
        SshTarget::new("studio.example", None, None).expect("valid target"),
        "/usr/bin/tmux",
        None,
    )
    .expect("valid remote host");
    let remote_host = remote_host_fixture(&config);
    let tmux_identity = session::SessionIdentity::new(42, "$1", 100);
    let snapshot = RemoteTmuxSnapshot::test_fixture(
        "studio.example",
        TEST_REMOTE_ROUTE,
        8,
        vec![session::DiscoveredSession::new(
            "work",
            tmux_identity.clone(),
            0,
        )],
        HerdrInventory::Unavailable,
        ZellijInventory::Unavailable,
    );
    a.scene
        .runtime
        .remote_hosts
        .lock()
        .expect("remote hosts")
        .insert(
            config.id().to_owned(),
            RemoteEntry {
                config,
                native_host: Some(remote_host.clone()),
                context: Some(RemoteHostContext {
                    generation: 8,
                    host: remote_host,
                    snapshot: snapshot.clone(),
                }),
                cancellation: None,
                constructive_cancellation: None,
                attachment_attempts: Vec::new(),
                generation: 8,
            },
        );
    let attempt_cancellation = CancellationToken::new();
    register_remote_attachment(
        &a.scene.runtime,
        b.scene.id,
        "ssh:studio",
        8,
        &snapshot,
        11,
        &attempt_cancellation,
    )
    .expect("register scene B's attach attempt");
    *b.scene.remote_active.lock().expect("remote active") = Some(RemoteActive {
        key: RemotePresentationKey {
            host_id: "ssh:studio".to_owned(),
            endpoint: "studio.example".to_owned(),
            route_identity: TEST_REMOTE_ROUTE.to_owned(),
            lease_generation: 8,
            session_identity: RemoteSessionIdentity::Tmux(tmux_identity),
        },
        selection: SessionSelection::new("ssh:studio", "studio.example", "work"),
        worker_generation: 99,
        lease: snapshot.lease().clone(),
        presentation_id: 42,
        term: AttachTerm::Xterm256Color,
        retainable: true,
        identity_mismatch_marker: None,
    });

    // A retained local presentation with its own live worker, and a remote
    // retained presentation holding another lease clone.
    let keepalive_worker = |name: &str, identity: session::SessionIdentity| {
        let plan = session::AttachPlan::attach_only(
            "cmd.exe",
            ["/d", "/q", "/k", "prompt", "close$G"]
                .into_iter()
                .map(std::ffi::OsString::from)
                .collect(),
            name,
            identity,
        );
        TerminalWorker::attach(&plan, GridSize::new(40, 4).expect("valid grid"))
            .expect("attach ConPTY client")
    };
    let retained_identity = session::SessionIdentity::new(101, "$2", 201);
    let retained_request =
        attach_request_fixture(&host_snapshot, retained_identity.clone(), "retained");
    b.scene
        .retained_presentations
        .lock()
        .expect("retained presentations")
        .insert(RetainedPresentation {
            key: retained_request.presentation_key(),
            selection: SessionSelection::new("wsl", "Ubuntu", "retained"),
            attachment: ActiveAttachment {
                request: retained_request,
                term: AttachTerm::Xterm256Color,
                generation: 1,
                fallback: None,
            },
            worker: keepalive_worker("retained", retained_identity),
            presentation_id: 7,
        });
    let remote_retained_identity = session::SessionIdentity::new(43, "$2", 101);
    b.scene
        .remote_retained
        .lock()
        .expect("remote retained")
        .entries
        .push(RemoteRetainedPresentation {
            active: RemoteActive {
                key: RemotePresentationKey {
                    host_id: "ssh:studio".to_owned(),
                    endpoint: "studio.example".to_owned(),
                    route_identity: TEST_REMOTE_ROUTE.to_owned(),
                    lease_generation: 8,
                    session_identity: RemoteSessionIdentity::Tmux(remote_retained_identity.clone()),
                },
                selection: SessionSelection::new("ssh:studio", "studio.example", "remote-retained"),
                worker_generation: 98,
                lease: snapshot.lease().clone(),
                presentation_id: 43,
                term: AttachTerm::Xterm256Color,
                retainable: true,
                identity_mismatch_marker: None,
            },
            worker: keepalive_worker("remote-retained", remote_retained_identity),
        });
    *b.scene
        .kill_capture_intent
        .lock()
        .expect("kill capture intent") = Some(KillCaptureIntent {
        generation: 0,
        selection: SessionSelection::new("wsl", "Ubuntu", "work"),
    });
    assert!(
        b.scene
            .retained_presentations
            .lock()
            .expect("retained presentations")
            .has_workers(),
        "a retained presentation is held before the close"
    );
    assert!(
        b.scene
            .remote_retained
            .lock()
            .expect("remote retained")
            .has_workers(),
        "a remote retained presentation is held before the close"
    );

    b.close();

    assert!(
        b.scene.worker.lock().expect("worker").active().is_none(),
        "no live worker survives the close"
    );
    assert!(
        b.scene
            .attachment
            .lock()
            .expect("attachment")
            .active()
            .is_none(),
        "the attachment slot is released"
    );
    assert!(
        b.scene
            .remote_active
            .lock()
            .expect("remote active")
            .is_none(),
        "the remote presentation and its held lease clone are released"
    );
    assert!(
        !b.scene
            .retained_presentations
            .lock()
            .expect("retained presentations")
            .has_workers(),
        "no retained presentation survives the close"
    );
    assert!(
        !b.scene
            .remote_retained
            .lock()
            .expect("remote retained")
            .has_workers(),
        "no remote retained presentation survives the close"
    );
    assert!(
        attempt_cancellation.is_cancelled(),
        "the dead scene's registered attach attempt is cancelled"
    );
    assert!(
        a.scene
            .runtime
            .remote_hosts
            .lock()
            .expect("remote hosts")
            .get("ssh:studio")
            .expect("remote entry")
            .attachment_attempts
            .is_empty(),
        "no attempt for the dead scene stays registered on the host"
    );
    assert!(
        b.scene
            .kill_capture_intent
            .lock()
            .expect("kill capture intent")
            .is_none(),
        "in-flight capture intents die with the scene"
    );
    let live = live_scenes(&a.scene.runtime);
    assert!(
        live.iter().all(|scene| scene.id != b.scene.id),
        "the closed scene is unregistered"
    );
    assert!(
        live.iter().any(|scene| scene.id == a.scene.id),
        "the surviving scene stays registered"
    );
}

#[test]
fn close_cancels_queued_addressed_requests_and_drops_lossless_settlements() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    push_lossless_event(
        &workspace.scene,
        WorkspaceEvent::KwtProjectMutationFinished {
            action: KwtProjectAction::Add,
        },
    );
    let (sender, receiver) = sync_channel(1);
    push_operation_event(
        &workspace.scene,
        WorkspaceEvent::SshPrompt(SshPromptRequest {
            host_id: "ssh:studio".to_owned(),
            generation: 7,
            prompt: host::SshLeasePrompt::test_fixture(),
            response: Arc::new(Mutex::new(Some(sender))),
        }),
    );

    workspace.close();

    assert_eq!(
        receiver.try_recv(),
        Ok(None),
        "the queued addressed request is cancelled at close, never silently discarded"
    );
    assert!(
        workspace
            .scene
            .operation_events
            .lock()
            .expect("scene inbox")
            .is_empty(),
        "the pending lossless settlement drains away with its dead dialog"
    );

    // A request addressed to the scene AFTER it died is cancelled on
    // arrival: the fail-closed path holds whether the scene dies before or
    // after the event lands in its inbox.
    let (late_sender, late_receiver) = sync_channel(1);
    push_operation_event(
        &workspace.scene,
        WorkspaceEvent::SshPrompt(SshPromptRequest {
            host_id: "ssh:studio".to_owned(),
            generation: 8,
            prompt: host::SshLeasePrompt::test_fixture(),
            response: Arc::new(Mutex::new(Some(late_sender))),
        }),
    );
    assert_eq!(
        late_receiver.try_recv(),
        Ok(None),
        "a request addressed to a dead scene cancels on arrival"
    );
    push_lossless_event(
        &workspace.scene,
        WorkspaceEvent::KwtProjectMutationFinished {
            action: KwtProjectAction::Add,
        },
    );
    assert!(
        workspace.drain_events().0.is_empty(),
        "nothing queues on a dead scene"
    );
}

#[test]
fn attach_parked_behind_a_closing_scene_fails_and_leaves_the_scene_empty() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let host_snapshot = HostSnapshot::test_fixture(
        "Ubuntu",
        "boot-id",
        42,
        vec![session::DiscoveredSession::new("work", identity, 0)],
    );
    let a = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    set_inventory_state(&a.scene.runtime, &ready_content(&host_snapshot));
    let b = a.open_scene();

    // Recreate the legitimate race: hold the navigation mutex, let the
    // close mark the scene and park behind the mutex for its detach, and
    // park an attach from another handle clone on the same mutex. Whichever
    // wakes first, the attach must observe the close and fail instead of
    // minting a fresh navigation generation and publishing a worker into
    // the dead scene.
    let guard = b
        .scene
        .navigation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let closer_handle = b.clone();
    let (closed_done, closed_finished) = std::sync::mpsc::channel();
    let closer = thread::spawn(move || {
        closer_handle.close();
        let _ = closed_done.send(());
    });
    settle("close marks the scene closed", || {
        b.scene.closed.load(Ordering::Acquire)
    });
    let attacher_handle = b.clone();
    let (attach_done, attach_finished) = std::sync::mpsc::channel();
    let attacher = thread::spawn(move || {
        let result = attacher_handle.attach(&SessionSelection::new("wsl", "Ubuntu", "work"));
        let _ = attach_done.send(());
        result
    });
    // Give the attacher time to park on the held mutex before releasing it.
    thread::sleep(Duration::from_millis(50));
    drop(guard);
    // Bounded joins: a reintroduced close/attach deadlock fails as a clean
    // timeout instead of hanging the suite.
    closed_finished
        .recv_timeout(Duration::from_secs(10))
        .expect("close settles instead of deadlocking");
    closer.join().expect("close task");

    attach_finished
        .recv_timeout(Duration::from_secs(10))
        .expect("attach settles instead of deadlocking");
    let error = attacher
        .join()
        .expect("attach task")
        .expect_err("a constructive entry on a closed scene fails closed");
    assert_eq!(
        error.to_string(),
        "the scene closed before this operation could start"
    );
    assert!(
        b.scene
            .attachment
            .lock()
            .expect("attachment")
            .active()
            .is_none(),
        "no attachment slot was re-armed in the dead scene"
    );
    assert!(
        b.scene.worker.lock().expect("worker").active().is_none(),
        "no worker was published into the dead scene"
    );
    assert!(
        b.scene
            .remote_active
            .lock()
            .expect("remote active")
            .is_none(),
        "no remote presentation was re-armed in the dead scene"
    );
    assert!(
        live_scenes(&a.scene.runtime)
            .iter()
            .all(|scene| scene.id != b.scene.id),
        "the closed scene stays unregistered"
    );
}

#[test]
fn prompt_requested_on_an_already_closed_scene_fails_without_queueing() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    workspace.close();

    let result = request_ssh_prompt(
        &workspace.scene,
        "ssh:studio",
        9,
        &host::SshLeasePrompt::test_fixture(),
        &CancellationToken::new(),
    );

    let error = result.expect_err("a closed scene mints no prompt request");
    assert_eq!(
        error.to_string(),
        host::SshError::prompt_cancelled().to_string()
    );
    assert!(
        workspace
            .scene
            .operation_events
            .lock()
            .expect("scene inbox")
            .is_empty(),
        "neither a request nor a dismissal was queued"
    );
}

#[cfg(windows)]
fn conpty_keepalive_worker(name: &str, identity: session::SessionIdentity) -> TerminalWorker {
    let plan = session::AttachPlan::attach_only(
        "cmd.exe",
        ["/d", "/q", "/k", "prompt", "close$G"]
            .into_iter()
            .map(std::ffi::OsString::from)
            .collect(),
        name,
        identity,
    );
    TerminalWorker::attach(&plan, GridSize::new(40, 4).expect("valid grid"))
        .expect("attach ConPTY client")
}

#[cfg(windows)]
#[test]
fn restored_retained_publish_refuses_a_closed_scene() {
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let request = attach_request_fixture(&snapshot, identity.clone(), "work");
    let presentation = RetainedPresentation {
        key: request.presentation_key(),
        selection: SessionSelection::new("wsl", "Ubuntu", "work"),
        attachment: ActiveAttachment {
            request,
            term: AttachTerm::Xterm256Color,
            generation: 1,
            fallback: None,
        },
        worker: conpty_keepalive_worker("work", identity),
        presentation_id: 9,
    };

    workspace.close();
    let closed_revision = workspace.scene.revision.load(Ordering::Acquire);
    publish_restored_retained_presentation(&workspace.scene, presentation);

    assert!(
        !workspace
            .scene
            .retained_presentations
            .lock()
            .expect("retained presentations")
            .has_workers(),
        "a restore that raced the close cannot insert into the dead scene"
    );
    assert_eq!(
        workspace.scene.revision.load(Ordering::Acquire),
        closed_revision,
        "a refused restore publishes nothing"
    );
}

#[cfg(windows)]
#[test]
fn zellij_kill_suppression_reaches_every_scene_and_restores_to_owners() {
    // Scene B — not the scene running the kill — retains a client of the
    // doomed session. The pre-kill suppression must close it there too,
    // and the failure restore must route it back to B, not to the
    // initiating scene.
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let b = a.open_scene();
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let request = zellij_attach_request_fixture(&snapshot, "work");
    b.scene
        .retained_presentations
        .lock()
        .expect("retained presentations")
        .insert(RetainedPresentation {
            key: request.presentation_key(),
            selection: SessionSelection::zellij("wsl", "Ubuntu", "work"),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm256Color,
                generation: 1,
                fallback: None,
            },
            worker: conpty_keepalive_worker("work", identity),
            presentation_id: 9,
        });

    let suppressed = a.close_zellij_presentations(snapshot.endpoint(), snapshot.runtime(), "work");
    assert_eq!(
        suppressed.len(),
        1,
        "the other scene's client is suppressed"
    );
    assert_eq!(suppressed[0].scene_id, b.scene.id);
    assert!(
        !b.scene
            .retained_presentations
            .lock()
            .expect("retained presentations")
            .has_workers(),
        "no client of the doomed session survives in any scene"
    );

    // The retained reopen spawns a real client, which this fixture cannot
    // do; the restore outcome — here its failure event — is what must land
    // on the owning scene and nowhere else.
    a.restore_suppressed_zellij_presentations(suppressed);
    let (b_events, _) = b.drain_events();
    assert!(
        b_events.iter().any(|event| matches!(
            event,
            WorkspaceEvent::Error(message) if message.contains("could not restore")
        )),
        "the restore outcome lands on the owning scene"
    );
    let (a_events, _) = a.drain_events();
    assert!(
        !a_events
            .iter()
            .any(|event| matches!(event, WorkspaceEvent::Error(_))),
        "the initiating scene never receives another scene's restore outcome"
    );
}

#[cfg(windows)]
#[test]
fn herdr_stop_suppression_reaches_every_scene_and_restores_to_owners() {
    let a = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let b = a.open_scene();
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let request = herdr_attach_request_fixture(&snapshot, "work");
    let record = session::HerdrSessionRecord::new(
        "work",
        false,
        HerdrSessionState::Running,
        "/tmp/herdr/review",
        "/tmp/herdr/review/herdr.sock",
    );
    let pending = PendingHerdrLifecycle {
        generation: a.scene.herdr_lifecycle_generation.load(Ordering::Acquire),
        operation_id: 1,
        selection: SessionSelection::herdr("wsl", "Ubuntu", "work"),
        action: HerdrLifecycleAction::Stop,
        host: WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            Arc::new(StdCommandRunner) as SharedCommandRunner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        ),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        executable: "/opt/herdr/bin/herdr".to_owned(),
        record,
    };
    b.scene
        .retained_presentations
        .lock()
        .expect("retained presentations")
        .insert(RetainedPresentation {
            key: request.presentation_key(),
            selection: SessionSelection::herdr("wsl", "Ubuntu", "work"),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm256Color,
                generation: 1,
                fallback: None,
            },
            worker: conpty_keepalive_worker("work", identity),
            presentation_id: 9,
        });

    let suppressed = a.close_herdr_presentations(&pending);
    assert_eq!(
        suppressed.len(),
        1,
        "the other scene's client is suppressed"
    );
    assert_eq!(suppressed[0].scene_id, b.scene.id);
    assert!(
        !b.scene
            .retained_presentations
            .lock()
            .expect("retained presentations")
            .has_workers(),
        "no client of the doomed session survives in any scene"
    );

    // As in the Zellij test: the reopen cannot spawn here, so the restore
    // outcome must land on the owning scene and nowhere else.
    a.restore_suppressed_herdr_presentations(suppressed);
    let (b_events, _) = b.drain_events();
    assert!(
        b_events.iter().any(|event| matches!(
            event,
            WorkspaceEvent::Error(message) if message.contains("could not restore")
        )),
        "the restore outcome lands on the owning scene"
    );
    let (a_events, _) = a.drain_events();
    assert!(
        !a_events
            .iter()
            .any(|event| matches!(event, WorkspaceEvent::Error(_))),
        "the initiating scene never receives another scene's restore outcome"
    );
}

#[cfg(windows)]
#[test]
fn kill_failure_restore_cannot_resurrect_a_presentation_in_a_closed_scene() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let request = zellij_attach_request_fixture(&snapshot, "work");
    workspace
        .scene
        .retained_presentations
        .lock()
        .expect("retained presentations")
        .insert(RetainedPresentation {
            key: request.presentation_key(),
            selection: SessionSelection::zellij("wsl", "Ubuntu", "work"),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm256Color,
                generation: 1,
                fallback: None,
            },
            worker: conpty_keepalive_worker("work", identity),
            presentation_id: 9,
        });

    // The kill worker suppresses the retained presentation before the slow
    // kill: the entry leaves the scene and rides in the suppression value.
    let suppressed = workspace
        .close_zellij_presentations(snapshot.endpoint(), snapshot.runtime(), "work")
        .into_iter()
        .next()
        .expect("the retained presentation is suppressed");
    assert!(
        suppressed.retained.is_some(),
        "the suppression carries the closed retained presentation"
    );

    // The scene closes mid-kill: release_scene drains an already-empty
    // retained set. The kill then fails and the worker runs the restore.
    workspace.close();
    workspace.restore_suppressed_zellij_presentation(Some(suppressed));

    assert!(
        !workspace
            .scene
            .retained_presentations
            .lock()
            .expect("retained presentations")
            .has_workers(),
        "no retained presentation reappears in the closed scene"
    );
    assert!(
        workspace
            .scene
            .worker
            .lock()
            .expect("worker")
            .active()
            .is_none(),
        "no live worker reappears in the closed scene"
    );
    assert!(
        workspace
            .scene
            .remote_active
            .lock()
            .expect("remote active")
            .is_none(),
        "no lease-holding presentation reappears in the closed scene"
    );
    assert!(
        workspace
            .scene
            .operation_events
            .lock()
            .expect("scene inbox")
            .is_empty(),
        "nothing queues on the dead scene"
    );
}

#[cfg(windows)]
#[test]
fn herdr_failure_restore_cannot_resurrect_a_presentation_in_a_closed_scene() {
    let workspace = Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let request = herdr_attach_request_fixture(&snapshot, "work");
    let record = session::HerdrSessionRecord::new(
        "work",
        false,
        HerdrSessionState::Running,
        "/tmp/herdr/review",
        "/tmp/herdr/review/herdr.sock",
    );
    let pending = PendingHerdrLifecycle {
        generation: workspace
            .scene
            .herdr_lifecycle_generation
            .load(Ordering::Acquire),
        operation_id: 1,
        selection: SessionSelection::herdr("wsl", "Ubuntu", "work"),
        action: HerdrLifecycleAction::Stop,
        host: WslHost::new(
            WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
            Arc::new(StdCommandRunner) as SharedCommandRunner,
            WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
                .expect("absolute WSL path"),
        ),
        endpoint: snapshot.endpoint().clone(),
        runtime: snapshot.runtime().clone(),
        executable: "/opt/herdr/bin/herdr".to_owned(),
        record,
    };
    workspace
        .scene
        .retained_presentations
        .lock()
        .expect("retained presentations")
        .insert(RetainedPresentation {
            key: request.presentation_key(),
            selection: SessionSelection::herdr("wsl", "Ubuntu", "work"),
            attachment: ActiveAttachment {
                request,
                term: AttachTerm::Xterm256Color,
                generation: 1,
                fallback: None,
            },
            worker: conpty_keepalive_worker("work", identity),
            presentation_id: 9,
        });

    // The lifecycle worker suppresses the retained presentation before the
    // slow Stop: the entry leaves the scene and rides in the suppression.
    let suppressed = workspace
        .close_herdr_presentations(&pending)
        .into_iter()
        .next()
        .expect("the retained presentation is suppressed");
    assert!(
        suppressed.retained.is_some(),
        "the suppression carries the closed retained presentation"
    );

    // The scene closes mid-operation: release_scene drains an already-empty
    // retained set. The Stop then fails and the worker runs the restore.
    workspace.close();
    workspace.restore_suppressed_herdr_presentation(Some(suppressed));

    assert!(
        !workspace
            .scene
            .retained_presentations
            .lock()
            .expect("retained presentations")
            .has_workers(),
        "no retained presentation reappears in the closed scene"
    );
    assert!(
        workspace
            .scene
            .worker
            .lock()
            .expect("worker")
            .active()
            .is_none(),
        "no live worker reappears in the closed scene"
    );
    assert!(
        workspace
            .scene
            .remote_active
            .lock()
            .expect("remote active")
            .is_none(),
        "no lease-holding presentation reappears in the closed scene"
    );
    assert!(
        workspace
            .scene
            .operation_events
            .lock()
            .expect("scene inbox")
            .is_empty(),
        "nothing queues on the dead scene"
    );
}

#[cfg(windows)]
#[test]
fn scene_close_denies_the_withheld_paste_at_the_live_worker() {
    let identity = session::SessionIdentity::new(100, "$1", 200);
    let snapshot = HostSnapshot::test_fixture("Ubuntu", "boot-id", 42, Vec::new());
    let workspace = Workspace::preview(WorkspaceSnapshot::shell(Appearance::default(), Vec::new()));
    set_inventory_state(&workspace.scene.runtime, &ready_content(&snapshot));
    let plan = session::AttachPlan::attach_only(
        "cmd.exe",
        ["/d", "/q", "/k", "prompt", "pump$G"]
            .into_iter()
            .map(std::ffi::OsString::from)
            .collect(),
        "work",
        identity,
    );
    let worker = TerminalWorker::attach(&plan, GridSize::new(80, 8).expect("valid grid"))
        .expect("attach ConPTY client");
    // A multi-line paste requires confirmation: the worker suspends command
    // intake and reports ConfirmPaste.
    worker
        .send_key(KeyInput::paste("echo first\r\necho second"))
        .expect("queue guarded paste");
    // The probe outlives the worker, so the deny stays observable after the
    // close tears the worker down.
    let probe = worker.paste_cancel_probe();
    let _generation = workspace
        .scene
        .worker
        .lock()
        .expect("worker")
        .publish(worker);
    // The pump registers the withheld paste against the LIVE worker's
    // generation, exactly as in production.
    settle("pump observes the paste confirmation", || {
        let _backlog = pump_once(&workspace.scene.runtime);
        workspace
            .scene
            .pending_paste
            .lock()
            .expect("pending paste")
            .is_some()
    });
    assert_eq!(
        probe.load(Ordering::Acquire),
        0,
        "no deny is delivered before the close"
    );

    workspace.close();

    // The strongest deterministic observable: once close() returns, the
    // worker is invalidated and unreachable, so the only moment this deny
    // could have been delivered is inside the close, through the still-live
    // active worker before its invalidation. A regression to the slot-only
    // clear leaves this count at zero. The deny's effect on a live worker
    // (suspended intake resumes) is pinned separately by
    // `shed_paste_confirmation_sends_the_worker_cancel_and_resumes_input`.
    assert_eq!(
        probe.load(Ordering::Acquire),
        1,
        "close delivers the paste deny to the live worker before invalidating it"
    );
    assert!(
        workspace
            .scene
            .worker
            .lock()
            .expect("worker")
            .active()
            .is_none(),
        "the denied worker is torn down with the scene"
    );
    assert!(
        workspace
            .scene
            .pending_paste
            .lock()
            .expect("pending paste")
            .is_none(),
        "the confirmation slot is cleared with the deny"
    );
}

fn relative_luminance(color: Rgb) -> f64 {
    let linear = |component: u8| {
        let value = f64::from(component) / 255.0;
        if value <= 0.040_45 {
            value / 12.92
        } else {
            ((value + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
}

fn contrast_ratio(first: Rgb, second: Rgb) -> f64 {
    let first = relative_luminance(first);
    let second = relative_luminance(second);
    let (lighter, darker) = if first >= second {
        (first, second)
    } else {
        (second, first)
    };
    (lighter + 0.05) / (darker + 0.05)
}

#[test]
fn light_themes_render_every_ansi_color_with_readable_contrast() {
    for theme in [TerminalTheme::ClearLight, TerminalTheme::Novel] {
        let (background, foreground) = theme.colors().expect("built-in theme colors");
        let appearance = Appearance {
            theme,
            font_family: "monospace".to_owned(),
            font_size: 14,
            background,
            foreground,
            cursor_style: CursorStyle::Block,
            allow_shell_integration_cursor: false,
            hide_mouse_while_typing: true,
        };
        let colors = default_colors(&appearance);
        let mut engine =
            TerminalEngine::with_default_colors(GridSize::new(16, 1).expect("valid grid"), colors);
        let mut output = Vec::new();
        for index in 0_u8..16 {
            let code = if index < 8 { 30 + index } else { 82 + index };
            output.extend_from_slice(format!("\x1b[{code}mX").as_bytes());
        }

        let _events = engine.process(&output);
        let frame = engine.surface().load();
        for column in 0..16 {
            let ratio = contrast_ratio(frame.row(0)[column].foreground, colors.background());
            assert!(
                ratio >= 4.5,
                "{theme:?} ANSI color {column} has only {ratio:.2}:1 contrast"
            );
        }
    }
}
