use session::probe::{ProbeNamespace, psmux_probe_plan};

#[test]
fn every_probe_command_is_confined_to_the_generated_namespace() {
    let namespace = ProbeNamespace::new("ghosthub-test-v27t-123").expect("valid namespace");
    let plan = psmux_probe_plan(&namespace);

    assert!(!plan.is_empty());
    for command in &plan {
        assert_eq!(
            &command.arguments()[..4],
            ["-f", "NUL", "-L", "ghosthub-test-v27t-123"],
            "{} escaped isolation",
            command.name()
        );
    }
}

#[test]
fn probe_plan_covers_each_load_bearing_psmux_command() {
    let namespace = ProbeNamespace::new("ghosthub-test-v27t-456").expect("valid namespace");
    let commands = psmux_probe_plan(&namespace)
        .into_iter()
        .map(|command| command.arguments().join(" "))
        .collect::<Vec<_>>();

    for required in [
        "new-session -A -d -s ghosthub -e GHOSTHUB_PROBE=present",
        "new-session -d -s ghosthub-old",
        "has-session -t =ghosthub",
        "has-session -t =ghost",
        "show-environment -t =ghosthub GHOSTHUB_PROBE",
        "display-message -p -t =ghosthub #{session_id}",
        "display-message -p -t =ghosthub #{pid}",
        "attach-session -E -t =ghosthub",
        "rename-session -t =ghosthub ghosthub-renamed",
        "kill-session -t =ghosthub-renamed",
        "has-session -t =ghosthub-old",
        "kill-server",
        "new-session -d -s server-restart",
        "display-message -p -t =server-restart #{pid}",
    ] {
        assert!(
            commands.iter().any(|command| command.ends_with(required)),
            "missing command: {required}"
        );
    }
}

#[test]
fn default_or_unscoped_namespaces_are_unrepresentable() {
    for invalid in [
        "",
        "default",
        "v27t-123",
        "ghosthub-test-",
        "ghosthub-test-bad space",
    ] {
        assert!(
            ProbeNamespace::new(invalid).is_err(),
            "accepted {invalid:?}"
        );
    }
}
