use session::probe::{ProbeNamespace, psmux_probe_plan};

#[test]
fn every_probe_command_is_confined_to_a_generated_namespace() {
    let namespace = ProbeNamespace::new("ghosthub-test-plan-123").expect("valid namespace");
    let plan = psmux_probe_plan(&namespace);

    assert!(!plan.is_empty());
    for command in &plan {
        assert_eq!(&command.arguments()[..3], ["-f", "NUL", "-L"]);
        assert!(
            matches!(
                command.arguments()[3].as_str(),
                "ghosthub-test-plan-123" | "ghosthub-test-plan-123-peer"
            ),
            "{} escaped isolation",
            command.name()
        );
    }
}

#[test]
fn probe_plan_covers_each_load_bearing_psmux_command() {
    let namespace = ProbeNamespace::new("ghosthub-test-plan-456").expect("valid namespace");
    let commands = psmux_probe_plan(&namespace)
        .into_iter()
        .map(|command| command.arguments().join(" "))
        .collect::<Vec<_>>();

    for required in [
        "new-session -A -d -s ghosthub-test-plan-456-main -e GHOSTHUB_PROBE=present",
        "new-session -d -s ghosthub-test-plan-456-main-old",
        "has-session -t =ghosthub-test-plan-456-main",
        "has-session -t =ghosthub-test-plan-456-main-o",
        "show-environment -t =ghosthub-test-plan-456-main GHOSTHUB_PROBE",
        "display-message -p -t =ghosthub-test-plan-456-main #{session_id}",
        "display-message -p -t =ghosthub-test-plan-456-main #{pid}",
        "attach-session -E -t =ghosthub-test-plan-456-main",
        "rename-session -t =ghosthub-test-plan-456-main ghosthub-test-plan-456-main-renamed",
        "kill-session -t =ghosthub-test-plan-456-main-renamed",
        "has-session -t =ghosthub-test-plan-456-main-old",
        "kill-server",
        "new-session -d -s ghosthub-test-plan-456-server-restart",
        "display-message -p -t =ghosthub-test-plan-456-server-restart #{pid}",
    ] {
        assert!(
            commands.iter().any(|command| command.ends_with(required)),
            "missing command: {required}"
        );
    }
}

#[test]
fn namespace_separation_is_proved_before_any_server_wide_command() {
    let namespace = ProbeNamespace::new("ghosthub-test-isolation-789").expect("valid namespace");
    let plan = psmux_probe_plan(&namespace);
    let first_server_kill = plan
        .iter()
        .position(|command| {
            command
                .arguments()
                .last()
                .is_some_and(|arg| arg == "kill-server")
        })
        .expect("server-wide cleanup command");
    let namespaces = plan[..first_server_kill]
        .iter()
        .filter_map(|command| {
            let marker = command.arguments().iter().position(|arg| arg == "-L")?;
            command.arguments().get(marker + 1).map(String::as_str)
        })
        .collect::<std::collections::BTreeSet<_>>();

    assert_eq!(
        namespaces,
        [
            "ghosthub-test-isolation-789",
            "ghosthub-test-isolation-789-peer",
        ]
        .into_iter()
        .collect()
    );
    assert!(
        plan[..first_server_kill].iter().any(|command| {
            command.arguments().join(" ").ends_with(
                "-L ghosthub-test-isolation-789 has-session -t =ghosthub-test-isolation-789-peer-sentinel",
            )
        }),
        "primary namespace never proved the peer sentinel absent"
    );
}

#[test]
fn default_or_unscoped_namespaces_are_unrepresentable() {
    for invalid in [
        "",
        "default",
        "probe-123",
        "ghosthub-test-",
        "ghosthub-test-bad space",
    ] {
        assert!(
            ProbeNamespace::new(invalid).is_err(),
            "accepted {invalid:?}"
        );
    }
}
