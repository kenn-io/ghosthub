---
title: Threat Model
description: Security boundaries and trust assumptions for Ghosthub
---

# Threat Model

This document defines the security claims Ghosthub makes and the assumptions
used to classify security findings. Ghosthub is a native terminal and tmux
control plane for one user across machines that user administers. It is not a
sandbox or a hardened client for attaching to hostile terminal servers.

## Assets and Security Goals

Ghosthub aims to protect:

- local user data exposed through app-mediated capabilities such as the
  clipboard
- terminal input and session metadata while they cross the network
- the non-destructive session boundary: Ghosthub may explicitly create a named
  session, but does not structurally mutate or destroy tmux sessions
- app-owned settings and persistence from unintended cross-host or
  cross-worktree mutation

The main security goals are to use the system SSH trust and encryption model,
avoid sending local data to a remote pane except through an intentional
terminal interaction, and keep tmux presentation non-destructive outside the
user's explicit named-session creation request.

## Trust Boundaries

### Local Mac and user account

The Mac running Ghosthub, the logged-in user account, and software intentionally
installed under that account are trusted. Ghosthub does not defend against a
compromised local account, injected libraries, replacement development tools,
or an attacker who can modify Ghosthub's configuration or state. Packaged
Ghosthub releases invoke their signed, bundled kwt by exact path rather than
trusting a launcher-controlled local `PATH`.

### Configured SSH hosts

Every remote host added to Ghosthub is a **trusted peer** administered by the
user. This trust includes the host operating system, its SSH service, the tmux
server and socket, and processes running in panes Ghosthub attaches to. SSH
host authentication and transport confidentiality are delegated to the user's
OpenSSH configuration and host-key policy.

A malicious or compromised configured SSH host is outside Ghosthub's threat
model. In particular, Ghosthub does not claim availability, confidentiality,
or protocol robustness when the remote SSH endpoint, tmux server, or attached
pane deliberately emits malformed, deceptive, or unbounded terminal output.
Resource limits and escape-sequence filtering on these paths
are defense-in-depth and correctness measures; they do not make a hostile host
a supported security boundary.

Trusting a host does not grant it every local app capability. Ghosthub still
applies its clipboard policy and other explicit terminal-integration controls
so routine remote programs cannot silently exercise local UI capabilities that
the user did not enable.

### Network

The network between Ghosthub and a configured host is untrusted. Passive
observers and active network attackers are in scope to the extent that SSH
normally protects against them. Ghosthub does not replace or weaken OpenSSH
host verification, authentication, or encryption.

### Local external state tools

Local state providers such as the bundled kwt, git, and tmux are trusted
programs running as the user. The embedded kwt revision is part of Ghosthub's
signed release input. Their output must still be validated for compatibility
and correctness, but deliberate compromise of those programs or their on-disk
state is outside the security model.

Names in the user's shared tmux server are identifiers, not credentials.
Ghosthub attaches to the exact session name reported by kwt or selected from
direct discovery. When the user explicitly requests a new named session,
Ghosthub may run local `tmux new-session -A -s <name>`, or one remote
create-if-absent phase using `has-session` and detached `new-session`. The name
is validated as a single command argument and the selected host identity is
fixed before launch. The remote creation authority is one-shot: after it
succeeds, transport recovery can only rerun `attach-session`. Existing
same-named sessions are attached without modifying their panes or windows.
Creation never grants authority to kill, rename, split, resize, or otherwise
structurally mutate sessions.

## In-Scope Failures

Security work should prioritize failures that cross a boundary without first
compromising a trusted component, including:

- sending clipboard contents or other local data to a remote pane without an
  intentional user action or enabled policy
- bypassing the user's SSH host identity and authentication policy
- confusing host, worktree, pane, or session identity in a way that mutates a
  different target
- killing or structurally mutating a tmux session through Ghosthub's ordinary
  presentation, outside the explicit creation of a user-named session
- exposing secrets through logs, persistence, or UI surfaces beyond their
  intended scope
- unsafe parsing or memory errors reachable from ordinary supported terminal
  and tmux behavior

Benign disconnects, reconnects, large but ordinary output, and valid tmux
layouts remain reliability and product-correctness concerns even when they are
not security-boundary violations.

## Explicitly Out of Scope

- a malicious or compromised configured SSH host
- a hostile tmux server or pane process on a configured host deliberately
  attacking the terminal parser
- denial of service caused by a trusted peer intentionally sending malformed
  or unbounded output
- compromise of the local Mac, user account, SSH agent, shell startup files,
  configuration, or locally installed command-line tools
- sandboxing commands the user chooses to run in a terminal pane
- availability of the network, SSH service, tmux server, or external state
  provider

## Review Classification

A report whose exploit prerequisite is only a malicious or compromised
configured SSH host is not a security release blocker under this threat model.
It may still identify worthwhile defense-in-depth or reliability work and
should be prioritized according to its effect during ordinary supported use.
Reports that cross an in-scope boundary, or that can be triggered without
control of a trusted peer, remain security issues.

Changes to these assumptions are product decisions. Update this document and
the relevant architecture or terminal-session contract in the same change
when Ghosthub begins supporting untrusted hosts, multi-user systems, sandboxed
workloads, or a different transport boundary.
