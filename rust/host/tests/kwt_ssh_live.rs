use host::{CancellationToken, KwtSshExecutable, KwtSshResolver, SshTarget, StdCommandRunner};

#[test]
#[ignore = "requires an explicitly staged native KWT controller"]
fn pinned_controller_resolves_the_native_ssh_contract() {
    let executable = std::env::var_os("GHOSTHUB_KWT_CONTROLLER_BUNDLE_TEST")
        .expect("set GHOSTHUB_KWT_CONTROLLER_BUNDLE_TEST to the native helper");
    let hostname =
        std::env::var("GHOSTHUB_SSH_RESOLVE_TARGET").unwrap_or_else(|_| "github.com".to_owned());
    let requested = SshTarget::new(hostname, None, None).expect("valid target");
    let resolver = KwtSshResolver::new(
        KwtSshExecutable::from_absolute(executable).expect("absolute helper"),
        StdCommandRunner,
    );

    let route = resolver
        .resolve(&requested, &CancellationToken::new())
        .expect("resolve route through pinned KWT");

    assert_eq!(route.logical_target(), &requested);
    assert_eq!(route.projection_policy(), "kwt.openssh.projection.v1");
    assert_eq!(route.route_identity().len(), 64);
    assert!(!route.targets().is_empty());
    assert_eq!(
        route
            .targets()
            .last()
            .map(host::SshResolvedTarget::logical_target),
        Some(&requested)
    );
}
