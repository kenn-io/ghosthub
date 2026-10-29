use super::{
    CancellationToken, CommandRunner, DiagnosticKind, Duration, RemoteCommandLocale,
    RemoteTmuxError, RemoteTmuxHost, RemoteTmuxSnapshot, SshLease, account_login_shell_command,
    extract_framed_command_output, framed_remote_shell_command, nonempty_diagnostic,
    payload_markers, posix_command, require_absolute, shell_quoted_argument, ssh_arguments,
    tmux_command,
};
use crate::kwt::{parse_command_failure, parse_project_mutation, validate_project_removal};
use crate::{CommandOutput, KwtBundle, KwtInventory, KwtProject};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RemoteKwtTarget {
    DarwinAmd64,
    DarwinArm64,
    LinuxAmd64,
    LinuxArm64,
}

impl RemoteKwtTarget {
    fn parse(os: &str, arch: &str) -> Result<Self, RemoteTmuxError> {
        match (os, arch) {
            ("Darwin", "x86_64" | "amd64") => Ok(Self::DarwinAmd64),
            ("Darwin", "arm64" | "aarch64") => Ok(Self::DarwinArm64),
            ("Linux", "x86_64" | "amd64") => Ok(Self::LinuxAmd64),
            ("Linux", "arm64" | "aarch64") => Ok(Self::LinuxArm64),
            _ => Err(RemoteTmuxError::new(
                DiagnosticKind::UnsupportedEnvironment,
                format!("This build does not include KWT for {os}/{arch}"),
            )),
        }
    }

    const fn checksum(self) -> &'static str {
        match self {
            Self::DarwinAmd64 | Self::DarwinArm64 => "/usr/bin/shasum -a 256",
            Self::LinuxAmd64 | Self::LinuxArm64 => "sha256sum",
        }
    }
}

impl<R: CommandRunner + Clone> RemoteTmuxHost<R> {
    /// Provision the pinned helper and read the three KWT inventory surfaces.
    ///
    /// # Errors
    /// Returns a helper, transport, command, or inventory error. Callers keep
    /// these failures scoped to projects, independently of terminal discovery.
    pub fn discover_kwt(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        cancellation: &CancellationToken,
    ) -> Result<KwtInventory, RemoteTmuxError> {
        let helper = self.ensure_kwt(snapshot.lease(), cancellation)?;
        let projects = self.kwt_command(
            snapshot.lease(),
            &helper,
            &["projects", "--json"],
            true,
            cancellation,
        )?;
        let worktrees = self.kwt_command(
            snapshot.lease(),
            &helper,
            &["list", "--global", "--json"],
            true,
            cancellation,
        )?;
        let directories = self.kwt_command(
            snapshot.lease(),
            &helper,
            &["workspace", "list", "--json"],
            true,
            cancellation,
        )?;
        KwtInventory::parse(&projects.stdout, &worktrees.stdout, &directories.stdout).map_err(
            |error| {
                RemoteTmuxError::new(
                    DiagnosticKind::MalformedOutput,
                    format!("KWT returned invalid inventory: {error}"),
                )
            },
        )
    }

    /// Register one explicit remote repository path through the pinned helper.
    ///
    /// # Errors
    /// Returns an error for an invalid path, unavailable helper, or rejected registration.
    pub fn register_kwt_project(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        path: &str,
        cancellation: &CancellationToken,
    ) -> Result<KwtProject, RemoteTmuxError> {
        require_absolute("remote project path", path)?;
        let helper = self.ensure_kwt(snapshot.lease(), cancellation)?;
        let output = self.kwt_command(
            snapshot.lease(),
            &helper,
            &["projects", "add", path, "--json"],
            false,
            cancellation,
        )?;
        parse_project_mutation(&output.stdout, "registered")
            .map_err(|error| RemoteTmuxError::new(DiagnosticKind::MalformedOutput, error))
    }

    /// Remove only the exact project registration confirmed by the user.
    ///
    /// # Errors
    /// Returns an error if the registration changed or the command fails.
    pub fn remove_kwt_project(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        expected: &KwtProject,
        cancellation: &CancellationToken,
    ) -> Result<KwtProject, RemoteTmuxError> {
        let fresh = self.discover_kwt(snapshot, cancellation)?;
        if !fresh.projects().iter().any(|item| {
            item.project().repository() == expected.repository()
                && item.project().path() == expected.path()
                && item.project().registration_fingerprint() == expected.registration_fingerprint()
        }) {
            return Err(RemoteTmuxError::new(
                DiagnosticKind::MalformedOutput,
                "The project registration changed; refresh and try again",
            ));
        }
        let helper = self.ensure_kwt(snapshot.lease(), cancellation)?;
        let output = self.kwt_command(
            snapshot.lease(),
            &helper,
            &[
                "projects",
                "remove",
                expected.path(),
                "--expected-repository",
                expected.repository(),
                "--expected-registration",
                expected.registration_fingerprint(),
                "--json",
            ],
            false,
            cancellation,
        )?;
        validate_project_removal(&output.stdout, expected)
            .map_err(|error| RemoteTmuxError::new(DiagnosticKind::MalformedOutput, error))?;
        Ok(expected.clone())
    }

    /// Build one interactive KWT open on the reviewed SSH connection.
    ///
    /// # Errors
    /// Returns an error when the lease or pinned helper is unavailable.
    pub fn kwt_worktree_open_plan(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        open: &crate::KwtWorktreeOpen,
        term: &str,
        cancellation: &CancellationToken,
    ) -> Result<session::RepairOrOpenPlan, RemoteTmuxError> {
        let helper = self.ensure_kwt(snapshot.lease(), cancellation)?;
        let readiness = crate::local::kwt_client_readiness_path()
            .map_err(|error| RemoteTmuxError::from_host(&error))?;
        let staging = format!("{readiness}.tmp");
        let mut command = tmux_command(
            &self.config,
            &helper,
            RemoteCommandLocale::Login,
            [
                "open",
                open.path(),
                "--expected-repository",
                open.repository(),
                "--expected-registration",
                open.registration_fingerprint(),
                "--expected-generation",
                open.generation(),
                "--expected-session",
                open.session_name(),
            ],
        );
        if let Some(value) = command.iter_mut().find(|value| value.starts_with("TERM=")) {
            *value = format!("TERM={term}");
        }
        let binary = snapshot.tmux_binary().ok_or_else(|| {
            RemoteTmuxError::new(
                DiagnosticKind::ExecutableNotFound,
                "tmux is unavailable on the remote host",
            )
        })?;
        let directory = binary
            .rsplit_once('/')
            .map_or("/", |(directory, _)| directory);
        // KWT execs its ordinary tmux client, preserving this recorded PID.
        let body = format!(
            "umask 077; set -C; printf '%s\\n' \"$$\" > {staging} && mv -f {staging} {readiness} && PATH={directory}:\"$PATH\" exec {command}",
            staging = shell_quoted_argument(&staging),
            readiness = shell_quoted_argument(&readiness),
            directory = shell_quoted_argument(directory),
            command = posix_command(&command),
        );
        Ok(session::RepairOrOpenPlan::worktree(
            self.ssh.program(),
            self.ssh.with_arguments(ssh_arguments(
                snapshot.lease(),
                self.config.target(),
                true,
                &account_login_shell_command(&body),
            )),
            open.session_name(),
            readiness,
        ))
    }

    /// Identify the actual tmux client started by KWT, on one supported server.
    ///
    /// # Errors
    /// Returns an error for a stale lease, invalid receipt, or failed server probe.
    pub fn kwt_client_identity(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        plan: &session::RepairOrOpenPlan,
        server: super::RemoteTmuxServer,
        cancellation: &CancellationToken,
    ) -> Result<Option<session::SessionIdentity>, RemoteTmuxError> {
        crate::local::require_kwt_client_readiness_path(plan.readiness_path())
            .map_err(|error| RemoteTmuxError::from_host(&error))?;
        let receipt = self.run_framed_remote_shell(
            snapshot.lease(),
            &format!(
                "if test -s {path}; then cat {path}; fi",
                path = shell_quoted_argument(plan.readiness_path()),
            ),
            "GHOSTHUB_KWT_CLIENT_",
            cancellation,
        )?;
        require_kwt_output(&receipt)?;
        if receipt.stdout.is_empty() {
            return Ok(None);
        }
        let pid = crate::local::parse_kwt_client_pid(&receipt.stdout)
            .map_err(|error| RemoteTmuxError::from_host(&error))?;
        let binary = snapshot.tmux_binary().ok_or_else(|| {
            RemoteTmuxError::new(
                DiagnosticKind::ExecutableNotFound,
                "tmux is unavailable on the remote host",
            )
        })?;
        let command = posix_command(&super::tmux_server_command(
            &self.config,
            server,
            binary,
            RemoteCommandLocale::StableOutput,
            [
                "list-clients",
                "-F",
                "#{client_pid}|#{pid}|#{session_id}|#{session_created}",
            ],
        ));
        let output = self.run_framed_remote_shell(
            snapshot.lease(),
            &command,
            "GHOSTHUB_KWT_CLIENT_",
            cancellation,
        )?;
        if output.status != 0
            && super::is_missing_tmux_server(&String::from_utf8_lossy(&output.stderr))
        {
            return Ok(None);
        }
        require_kwt_output(&output)?;
        crate::local::parse_kwt_client_identity(&output.stdout, pid, '|')
            .map_err(|error| RemoteTmuxError::from_host(&error))
    }

    pub fn remove_kwt_client_readiness(
        &self,
        snapshot: &RemoteTmuxSnapshot,
        plan: &session::RepairOrOpenPlan,
    ) {
        if crate::local::require_kwt_client_readiness_path(plan.readiness_path()).is_err() {
            return;
        }
        let _cleanup = self.run_remote_shell_with_timeout(
            snapshot.lease(),
            &format!(
                "rm -f -- {} {}",
                shell_quoted_argument(plan.readiness_path()),
                shell_quoted_argument(&format!("{}.tmp", plan.readiness_path())),
            ),
            &CancellationToken::new(),
            Duration::from_secs(2),
        );
    }

    fn ensure_kwt(
        &self,
        lease: &SshLease,
        cancellation: &CancellationToken,
    ) -> Result<String, RemoteTmuxError> {
        let probe = self.run_framed_remote_shell(
            lease,
            "uname -s && uname -m && printf '%s\\n' \"$HOME\"",
            "GHOSTHUB_KWT_TARGET_",
            cancellation,
        )?;
        require_kwt_output(&probe)?;
        let text = std::str::from_utf8(&probe.stdout).map_err(|_| {
            RemoteTmuxError::new(
                DiagnosticKind::MalformedOutput,
                "Invalid remote KWT platform response",
            )
        })?;
        let lines: Vec<_> = text.lines().collect();
        let [os, arch, home] = lines.as_slice() else {
            return Err(RemoteTmuxError::new(
                DiagnosticKind::MalformedOutput,
                "Invalid remote KWT platform response",
            ));
        };
        require_absolute("remote HOME", home)?;
        let target = RemoteKwtTarget::parse(os, arch)?;
        let bundle = self
            .config
            .kwt_bundles
            .iter()
            .find(|(candidate, _)| *candidate == target)
            .map(|(_, bundle)| bundle)
            .ok_or_else(|| {
                RemoteTmuxError::new(
                    DiagnosticKind::ExecutableNotFound,
                    "This build does not contain the pinned remote KWT helper",
                )
            })?;
        let directory = format!("{home}/.ghosthub/helpers/kwt/{}", bundle.revision());
        let path = format!("{directory}/kwt");
        let ready = self.run_framed_remote_shell(
            lease,
            &helper_matches(&path, target, bundle),
            "GHOSTHUB_KWT_READY_",
            cancellation,
        )?;
        if ready.status == 0 {
            return Ok(path);
        }

        let (nonce, _) = payload_markers("incoming-")?;
        let incoming = format!("{directory}/{nonce}");
        let install = format!(
            "umask 077; mkdir -p {directory} || exit $?; ghosthub_incoming={incoming}; \
             trap 'rm -f -- \"$ghosthub_incoming\"' HUP INT TERM; \
             cat > \"$ghosthub_incoming\" || exit $?; \
             chmod 0755 \"$ghosthub_incoming\" || exit $?; {verify}",
            directory = shell_quoted_argument(&directory),
            incoming = shell_quoted_argument(&incoming),
            verify = helper_matches(&incoming, target, bundle),
        );
        let result = self
            .upload_kwt(lease, &install, bundle.bytes(), cancellation)
            .and_then(|output| require_kwt_output(&output))
            .and_then(|()| {
                self.run_framed_remote_shell(
                    lease,
                    &format!(
                        "mv -f -- {} {}",
                        shell_quoted_argument(&incoming),
                        shell_quoted_argument(&path)
                    ),
                    "GHOSTHUB_KWT_ACTIVATE_",
                    cancellation,
                )
                .and_then(|output| require_kwt_output(&output))
            });
        if result.is_err() {
            // Cleanup uses a fresh token because the transfer may have been cancelled.
            let _cleanup = self.run_framed_remote_shell(
                lease,
                &format!("rm -f -- {}", shell_quoted_argument(&incoming)),
                "GHOSTHUB_KWT_CLEANUP_",
                &CancellationToken::new(),
            );
        }
        result?;
        let ready = self.run_framed_remote_shell(
            lease,
            &helper_matches(&path, target, bundle),
            "GHOSTHUB_KWT_READY_",
            cancellation,
        )?;
        require_kwt_output(&ready)?;
        Ok(path)
    }

    fn upload_kwt(
        &self,
        lease: &SshLease,
        command: &str,
        bytes: &[u8],
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, RemoteTmuxError> {
        lease
            .ensure_live()
            .map_err(|error| RemoteTmuxError::ssh(&error))?;
        let (begin, end) = payload_markers("GHOSTHUB_KWT_INSTALL_")?;
        let command = framed_remote_shell_command(command, &begin, &end);
        let output = self
            .runner
            .run_with_input(
                self.ssh.program(),
                &self.ssh.with_arguments(ssh_arguments(
                    lease,
                    self.config.target(),
                    false,
                    &account_login_shell_command(&command),
                )),
                bytes,
                cancellation,
                Duration::from_mins(2),
            )
            .map_err(|error| RemoteTmuxError::command_execution(&error))?;
        lease
            .ensure_live()
            .map_err(|error| RemoteTmuxError::ssh(&error))?;
        extract_framed_command_output(output, &begin, &end)
    }

    fn kwt_command(
        &self,
        lease: &SshLease,
        helper: &str,
        args: &[&str],
        read: bool,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, RemoteTmuxError> {
        let command = posix_command(&tmux_command(
            &self.config,
            helper,
            RemoteCommandLocale::Login,
            args.iter().copied(),
        ));
        let mut delays = [1, 4, 15].into_iter();
        loop {
            let output = self.run_framed_remote_shell(
                lease,
                &command,
                "GHOSTHUB_KWT_COMMAND_",
                cancellation,
            )?;
            if output.status == 0 {
                return Ok(output);
            }
            let failure = parse_command_failure(&output.stdout)
                .or_else(|| parse_command_failure(&output.stderr));
            if read
                && failure.is_some_and(|failure| failure.retryable())
                && let Some(delay) = delays.next()
                && !cancellation.wait_cancelled(Duration::from_secs(delay))
            {
                continue;
            }
            require_kwt_output(&output)?;
        }
    }
}

fn helper_matches(path: &str, target: RemoteKwtTarget, bundle: &KwtBundle) -> String {
    format!(
        "[ -x {path} ] && \
        ghosthub_digest=$({checksum} {path}) && \
        [ \"${{ghosthub_digest%% *}}\" = {digest} ] && \
        ghosthub_version=$({path} version) && \
        [ \"$(printf '%s\\n' \"$ghosthub_version\" | sed -n '1p')\" = {version} ]",
        path = shell_quoted_argument(path),
        checksum = target.checksum(),
        digest = shell_quoted_argument(bundle.sha256()),
        version = shell_quoted_argument(&format!("kwt version {}", bundle.revision()))
    )
}

fn require_kwt_output(output: &CommandOutput) -> Result<(), RemoteTmuxError> {
    if output.status == 0 {
        return Ok(());
    }
    let message = crate::kwt_command_failure_message(&output.stdout)
        .or_else(|| crate::kwt_command_failure_message(&output.stderr))
        .unwrap_or_else(|| nonempty_diagnostic(&output.stderr, "Remote KWT command failed"));
    Err(RemoteTmuxError::new(DiagnosticKind::Transport, message))
}
