import GhosthubTransport
import Combine
import Foundation
import GhosthubSettings
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

private let sessionIdentity = TmuxSessionIdentity(
    serverPID: "31415",
    sessionID: "$42",
    createdAt: "1785182057"
)
private let primaryStyle = TmuxPresentationStyle(
    foreground: "#DDEEFF",
    background: "#101820"
)
private let newerStyle = TmuxPresentationStyle(
    foreground: "#112233",
    background: "#F0F1F2"
)

@Suite("workspace tmux themes", .serialized)
struct WorkspaceTmuxThemeTests {
    @Test("follow-config uses effective libghostty colors")
    func followConfigStyle() {
        let preferences = TerminalAppearancePreferences(
            theme: .followConfig,
            appliesThemeToTmuxSessions: true,
            usesCustomFont: false,
            fontFamily: "Berkeley Mono",
            fontSize: 13
        )

        #expect(TmuxPresentationStyleResolver.resolve(
            preferences: preferences,
            resolvedColors: TerminalResolvedColors(
                foreground: "#112233",
                background: "#EEF0F2"
            )
        ) == TmuxPresentationStyle(
            foreground: "#112233",
            background: "#EEF0F2"
        ))
        #expect(TmuxPresentationStyleResolver.resolve(
            preferences: preferences,
            resolvedColors: nil
        ) == nil)
    }

    @Test("built-in themes ignore runtime colors")
    func builtInStyles() throws {
        let runtimeColors = TerminalResolvedColors(
            foreground: "#010203",
            background: "#040506"
        )

        for theme in TerminalTheme.allCases where theme != .followConfig {
            let spec = try #require(theme.spec)
            let preferences = TerminalAppearancePreferences(
                theme: theme,
                appliesThemeToTmuxSessions: true,
                usesCustomFont: false,
                fontFamily: "Berkeley Mono",
                fontSize: 13
            )
            #expect(TmuxPresentationStyleResolver.resolve(
                preferences: preferences,
                resolvedColors: runtimeColors
            ) == TmuxPresentationStyle(
                foreground: spec.foreground.hexRGB,
                background: spec.background.hexRGB
            ))
        }
    }

    @MainActor
    @Test("eligibility requires an active connected attachment")
    func eligibilityRequiresConnectedAttachment() async throws {
        let scene = try makeThemedScene(
            stylesExistingSessions: false,
            tmuxPresentationStyleProvider: { _ in primaryStyle }
        )

        #expect(!scene.model.canApplyThemeToActiveTmuxSession)
        scene.model.openBorrowedTmuxSession(scene.selection)
        #expect(!scene.model.canApplyThemeToActiveTmuxSession)
        await connectActiveTmuxSession(scene.model, store: scene.store)
        #expect(scene.model.canApplyThemeToActiveTmuxSession)
        await scene.model.shutdown()
    }

    @MainActor
    @Test("eligibility rejects missing styles and native Windows hosts")
    func eligibilityRejectsUnavailableTargets() async throws {
        let localScene = try makeThemedScene(
            stylesExistingSessions: false,
            tmuxPresentationStyleProvider: { _ in nil }
        )
        await localScene.openAndConnect()
        #expect(!localScene.model.canApplyThemeToActiveTmuxSession)
        await localScene.model.shutdown()

        let remote = try setupRemoteEnvironment()
        var windowsSnapshot = remote.snapshot
        windowsSnapshot.hosts[0].platform = .windows
        let windowsStore = ThemeTmuxSurfaceStoreStub()
        let windowsModel = try makeModel(
            database: remote.database,
            localHostID: UUID(),
            snapshot: windowsSnapshot,
            nativeTmuxSurfaceStore: windowsStore,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("tmux.exe") },
            tmuxPresentationStyleProvider: { _ in primaryStyle }
        )
        windowsModel.openBorrowedTmuxSession(
            WorkspaceTmuxSessionSelection(
                hostID: remote.host.id,
                name: "review"
            )
        )
        await connectActiveTmuxSession(windowsModel, store: windowsStore)
        #expect(!windowsModel.canApplyThemeToActiveTmuxSession)
        #expect(!windowsModel.canSplitActivePane)
        await windowsModel.shutdown()
    }

    @MainActor
    @Test("theme application rejects a session other than the active attachment")
    func rejectsInactiveSelection() async throws {
        let scene = try makeThemedScene(
            stylesExistingSessions: false,
            tmuxPresentationStyleProvider: { _ in primaryStyle },
            tmuxSessionStyler: { _, _, _, _ in
                Issue.record("Styler must not run for an inactive session")
            }
        )
        await scene.openAndConnect()

        await #expect {
            try await scene.model.applyTheme(
                to: WorkspaceTmuxSessionSelection(
                    hostID: scene.selection.hostID,
                    name: "other"
                )
            )
        } throws: { _ in true }
        await scene.model.shutdown()
    }

    @MainActor
    @Test("theme application captures the active target before suspension")
    func capturesActiveTarget() async throws {
        let calls = LockedValue<[(
            TmuxPresentationStyle,
            WorkspaceTmuxSessionSelection,
            TmuxSessionIdentity,
            CommandHost
        )]>([])
        let gate = StylerGate()
        let scene = try makeThemedScene(
            stylesExistingSessions: false,
            sessionName: "review",
            socketName: "protected",
            tmuxPresentationStyleProvider: { _ in primaryStyle },
            tmuxSessionStyler: { style, selection, identity, host in
                calls.withLock {
                    $0.append((style, selection, identity, host))
                }
                await gate.blockUntilOpened()
            }
        )
        await scene.openAndConnect()

        let task = Task {
            try await scene.model.applyTheme(to: scene.selection)
        }
        await gate.waitUntilBlocked()
        scene.model.openBorrowedTmuxSession(WorkspaceTmuxSessionSelection(
            hostID: scene.selection.hostID,
            name: "other"
        ))
        gate.open()
        try await task.value

        let recorded = calls.load()
        let call = try #require(recorded.count == 1 ? recorded[0] : nil)
        #expect(call.0 == primaryStyle)
        #expect(call.1 == scene.selection)
        #expect(call.2 == sessionIdentity)
        #expect(call.3 == .local)
        await scene.model.shutdown()
    }

    @MainActor
    @Test("theme application resolves colors for the active attachment surface")
    func resolvesStyleForActiveSurface() async throws {
        let requestedIdentities = LockedValue<[UInt?]>([])
        let appliedStyles = LockedValue<[TmuxPresentationStyle]>([])
        let scene = try makeThemedScene(
            stylesExistingSessions: false,
            tmuxPresentationStyleProvider: { identity in
                requestedIdentities.withLock { $0.append(identity) }
                return identity == 42 ? primaryStyle : nil
            },
            tmuxSessionStyler: { style, _, _, _ in
                appliedStyles.withLock { $0.append(style) }
            }
        )
        await scene.openAndConnect()

        #expect(scene.model.canApplyThemeToActiveTmuxSession)
        try await scene.model.applyTheme(to: scene.selection)

        #expect(requestedIdentities.load().last == 42)
        #expect(appliedStyles.load() == [primaryStyle])
        await scene.model.shutdown()
    }

    @MainActor
    @Test("color publications apply after the runtime updates")
    func colorPublicationsApplyAfterRuntimeUpdate() async throws {
        let colors = TerminalResolvedColors(
            foreground: "#DDEEFF",
            background: "#101820"
        )
        let publishedColors = CurrentValueSubject<
            [UInt: TerminalResolvedColors], Never
        >([:])
        var runtimeColors: [UInt: TerminalResolvedColors] = [:]
        let appliedStyles = LockedValue<[TmuxPresentationStyle]>([])
        let scene = try makeThemedScene(
            terminalColorsPublisher: publishedColors.eraseToAnyPublisher(),
            tmuxPresentationStyleProvider: { identity in
                guard let identity,
                      let resolved = runtimeColors[identity]
                else { return nil }
                return TmuxPresentationStyle(
                    foreground: resolved.foreground,
                    background: resolved.background
                )
            },
            tmuxSessionStyler: { style, _, _, _ in
                appliedStyles.withLock { $0.append(style) }
            }
        )
        await scene.openAndConnect()

        let update = [UInt(42): colors]
        publishedColors.send(update)
        runtimeColors = update
        await waitUntilMainActor {
            appliedStyles.load() == [primaryStyle]
        }

        await scene.model.shutdown()
    }

    @MainActor
    @Test("general discovery resumes deferred created-session styling")
    func generalDiscoveryResumesDeferredCreatedSessionStyling() async throws {
        let identityReads = LockedValue(0)
        let appliedIdentities = LockedValue<[TmuxSessionIdentity]>([])
        let generalDiscoveryCanFindSession = LockedValue(false)
        let scene = try makeThemedScene(
            stylesExistingSessions: false,
            sessionName: "first-session",
            tmuxSessionDiscovery: { _ in
                guard generalDiscoveryCanFindSession.load() else {
                    return .success([])
                }
                return .success([
                    DiscoveredTmuxSession(
                        name: "first-session",
                        windowCount: 1,
                        serverPID: sessionIdentity.serverPID,
                        sessionID: sessionIdentity.sessionID,
                        createdAt: sessionIdentity.createdAt,
                        managed: false
                    ),
                ])
            },
            tmuxSessionIdentityReader: { selection, host in
                identityReads.withLock { $0 += 1 }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            },
            createdSessionDiscoveryDelays: [.milliseconds(1)],
            tmuxPresentationStyleProvider: { identity in
                identity == 42 ? primaryStyle : nil
            },
            tmuxSessionStyler: { _, _, identity, _ in
                appliedIdentities.withLock { $0.append(identity) }
            }
        )

        scene.model.createTmuxSession(scene.selection)
        await connectActiveTmuxSession(scene.model, store: scene.store)
        await waitUntilMainActor {
            scene.model.exhaustedCreatedTmuxSessionCount == 1
        }
        #expect(appliedIdentities.load().isEmpty)

        generalDiscoveryCanFindSession.store(true)
        scene.model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            scene.model.pendingCreatedTmuxSessionCount == 0
                && appliedIdentities.load() == [sessionIdentity]
        }

        #expect(identityReads.load() == 0)
        await scene.model.shutdown()
    }

    @MainActor
    @Test("inactive styling supersedes colors changed during an apply")
    func inactiveStylingSupersedesChangedColors() async throws {
        let environment = try setupHostEnvironment()
        let store = ThemeTmuxSurfaceStoreStub(
            surfaceIdentities: [42, 43]
        )
        var resolvedStyles: [UInt: TmuxPresentationStyle] = [:]
        let appliedStyles = LockedValue<
            [String: [TmuxPresentationStyle]]
        >([:])
        let gate = StylerGate()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            tmuxPresentationStyleProvider: { identity in
                identity.flatMap { resolvedStyles[$0] }
            },
            appliesTmuxPresentationStyleToExistingSessionsProvider: { true },
            tmuxSessionIdentityReader: { _, _ in sessionIdentity },
            tmuxSessionStyler: { style, selection, _, _ in
                appliedStyles.withLock {
                    $0[selection.name, default: []].append(style)
                }
                if selection.name == "first", style == primaryStyle {
                    await gate.blockUntilOpened()
                    throw CancellationError()
                }
            }
        )
        let first = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "first"
        )
        let second = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "second"
        )
        model.openBorrowedTmuxSession(first)
        await connectActiveTmuxSession(model, store: store)
        model.openBorrowedTmuxSession(second)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return store.requestCount == 2
                && model.activeBorrowedTmuxSessionIsConnected
        }

        resolvedStyles = [42: primaryStyle, 43: newerStyle]
        model.terminalPresentationStyleDidChange()
        await gate.waitUntilBlocked()
        await waitUntilMainActor {
            appliedStyles.load()["second"] == [newerStyle]
        }

        resolvedStyles[42] = newerStyle
        model.terminalPresentationStyleDidChange()
        try await Task.sleep(for: .milliseconds(50))
        #expect(appliedStyles.load()["first"] == [primaryStyle])

        gate.open()
        await waitUntilMainActor {
            appliedStyles.load()["first"] == [primaryStyle, newerStyle]
                && model.tmuxStylingQuiesced
        }
        #expect(model.activeBorrowedTmuxSelection == second)
        await model.shutdown()
    }

    @MainActor
    @Test("remote deferred kwt styling applies once with the read identity")
    func remoteDeferredKwtStylingAppliesOnce() async throws {
        let environment = try setupRemoteEnvironment()
        let store = ThemeTmuxSurfaceStoreStub(surfaceIdentity: 42)
        var resolvedStyle: TmuxPresentationStyle?
        let appliedStyles = LockedValue<[TmuxPresentationStyle]>([])
        let appliedIdentities = LockedValue<[TmuxSessionIdentity]>([])
        let model = try makeModel(
            database: environment.database,
            localHostID: UUID(),
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            tmuxPresentationStyleProvider: { _ in resolvedStyle },
            appliesTmuxPresentationStyleToExistingSessionsProvider: { true },
            tmuxSessionIdentityReader: { _, _ in sessionIdentity },
            tmuxSessionStyler: { style, _, identity, _ in
                appliedStyles.withLock { $0.append(style) }
                appliedIdentities.withLock { $0.append(identity) }
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "first-session",
            worktreeID: UUID(),
            worktreePath: "/tmp/ghosthub"
        )
        model.openBorrowedTmuxSession(selection)
        await connectActiveTmuxSession(model, store: store)

        resolvedStyle = primaryStyle
        model.terminalPresentationStyleDidChange()
        await waitUntilMainActor {
            appliedStyles.load() == [primaryStyle]
                && model.tmuxStylingQuiesced
        }

        model.terminalPresentationStyleDidChange()
        try await Task.sleep(for: .milliseconds(50))

        #expect(appliedStyles.load() == [primaryStyle])
        #expect(appliedIdentities.load() == [sessionIdentity])
        await model.shutdown()
    }

    @MainActor
    @Test("a superseded ladder drains before the latest colors apply")
    func supersededStylingDrainsBeforeLatestColors() async throws {
        var resolvedStyle: TmuxPresentationStyle?
        let appliedStyles = LockedValue<[TmuxPresentationStyle]>([])
        let gate = StylerGate()
        let scene = try makeThemedScene(
            stylesExistingSessions: false,
            sessionName: "first-session",
            tmuxSessionDiscovery: { _ in
                .success([
                    DiscoveredTmuxSession(
                        name: "first-session",
                        windowCount: 1,
                        serverPID: sessionIdentity.serverPID,
                        sessionID: sessionIdentity.sessionID,
                        createdAt: sessionIdentity.createdAt,
                        managed: false
                    ),
                ])
            },
            createdSessionDiscoveryDelays: [.milliseconds(1)],
            tmuxPresentationStyleProvider: { _ in resolvedStyle },
            tmuxSessionStyler: { style, _, _, _ in
                let isFirstApply = appliedStyles.load().isEmpty
                appliedStyles.withLock { $0.append(style) }
                if isFirstApply {
                    await gate.blockUntilOpened()
                    throw CancellationError()
                }
            }
        )
        scene.model.createTmuxSession(scene.selection)
        await connectActiveTmuxSession(scene.model, store: scene.store)
        await waitUntilMainActor {
            scene.model.pendingCreatedTmuxSessionCount == 0
        }
        #expect(appliedStyles.load().isEmpty)

        resolvedStyle = primaryStyle
        scene.model.terminalPresentationStyleDidChange()
        await gate.waitUntilBlocked()

        resolvedStyle = newerStyle
        scene.model.terminalPresentationStyleDidChange()
        try await Task.sleep(for: .milliseconds(50))
        #expect(appliedStyles.load() == [primaryStyle])

        gate.open()
        await waitUntilMainActor {
            appliedStyles.load() == [primaryStyle, newerStyle]
        }

        await scene.model.shutdown()
    }

    @MainActor
    @Test("deferred styling retries a transient failure")
    func deferredStylingRetriesTransientFailure() async throws {
        var resolvedStyle: TmuxPresentationStyle?
        let attempts = LockedValue(0)
        let scene = try makeThemedScene(
            tmuxPresentationStyleProvider: { _ in resolvedStyle },
            tmuxSessionStyler: { _, _, _, _ in
                attempts.withLock { $0 += 1 }
                if attempts.load() == 1 {
                    throw TmuxSessionKillError.sessionNotRunning(
                        host: "local",
                        session: "review"
                    )
                }
            }
        )
        await scene.openAndConnect()

        resolvedStyle = primaryStyle
        scene.model.terminalPresentationStyleDidChange()
        await waitUntilMainActor(timeout: .seconds(1)) {
            attempts.load() == 2
        }

        await scene.model.shutdown()
    }

    @MainActor
    @Test("deferred retries pin the first read session identity")
    func deferredRetriesPinFirstReadIdentity() async throws {
        let replacementIdentity = TmuxSessionIdentity(
            serverPID: "27182",
            sessionID: "$7",
            createdAt: "1785182999"
        )
        var resolvedStyle: TmuxPresentationStyle?
        let identityReads = LockedValue(0)
        let appliedIdentities = LockedValue<[TmuxSessionIdentity]>([])
        let attempts = LockedValue(0)
        let scene = try makeThemedScene(
            tmuxSessionIdentityReader: { _, _ in
                identityReads.withLock { $0 += 1 }
                return identityReads.load() == 1
                    ? sessionIdentity
                    : replacementIdentity
            },
            deferredTmuxPresentationRetryDelays: [.milliseconds(1)],
            tmuxPresentationStyleProvider: { _ in resolvedStyle },
            tmuxSessionStyler: { _, _, identity, _ in
                attempts.withLock { $0 += 1 }
                if attempts.load() == 1 {
                    throw TmuxSessionStyleError.commandFailed(
                        host: "local", session: "review", status: 1
                    )
                }
                appliedIdentities.withLock { $0.append(identity) }
            }
        )
        await scene.openAndConnect()

        resolvedStyle = primaryStyle
        scene.model.terminalPresentationStyleDidChange()
        await waitUntilMainActor(timeout: .seconds(1)) {
            appliedIdentities.load() == [sessionIdentity]
        }

        #expect(identityReads.load() == 1)
        await scene.model.shutdown()
    }

    @MainActor
    @Test("a replaced session stops the deferred ladder")
    func deferredStylingStopsWhenSessionChanged() async throws {
        var resolvedStyle: TmuxPresentationStyle?
        let attempts = LockedValue(0)
        let scene = try makeThemedScene(
            deferredTmuxPresentationRetryDelays: [.milliseconds(1)],
            tmuxPresentationStyleProvider: { _ in resolvedStyle },
            tmuxSessionStyler: { _, _, _, _ in
                attempts.withLock { $0 += 1 }
                throw TmuxSessionStyleError.sessionChanged(
                    host: "local", session: "review"
                )
            }
        )
        await scene.openAndConnect()

        resolvedStyle = primaryStyle
        scene.model.terminalPresentationStyleDidChange()
        await waitUntilMainActor(timeout: .seconds(1)) {
            attempts.load() == 1 && scene.model.tmuxStylingQuiesced
        }

        // The marker is consumed: later triggers must not rearm the ladder.
        scene.model.terminalPresentationStyleDidChange()
        try await Task.sleep(for: .milliseconds(50))
        #expect(attempts.load() == 1)

        await scene.model.shutdown()
    }

    @MainActor
    @Test("back-to-back publications before the first apply still style")
    func rapidPublicationsBeforeFirstApplyStillStyle() async throws {
        var resolvedStyle: TmuxPresentationStyle?
        let appliedStyles = LockedValue<[TmuxPresentationStyle]>([])
        let scene = try makeThemedScene(
            tmuxPresentationStyleProvider: { _ in resolvedStyle },
            tmuxSessionStyler: { style, _, _, _ in
                appliedStyles.withLock { $0.append(style) }
            }
        )
        await scene.openAndConnect()

        // No suspension between the two publications: the first task is
        // cancelled before its closure ever runs.
        resolvedStyle = primaryStyle
        scene.model.terminalPresentationStyleDidChange()
        resolvedStyle = newerStyle
        scene.model.terminalPresentationStyleDidChange()
        await waitUntilMainActor {
            appliedStyles.load() == [newerStyle]
        }

        await scene.model.shutdown()
    }

    @MainActor
    @Test("manual application waits out a blocked deferred command")
    func manualApplicationDrainsBlockedDeferredCommand() async throws {
        var resolvedStyle: TmuxPresentationStyle?
        let appliedStyles = LockedValue<[TmuxPresentationStyle]>([])
        let stylerCalls = LockedValue(0)
        let gate = StylerGate()
        let scene = try makeThemedScene(
            tmuxPresentationStyleProvider: { _ in resolvedStyle },
            tmuxSessionStyler: { style, _, _, _ in
                stylerCalls.withLock { $0 += 1 }
                if stylerCalls.load() == 1 {
                    await gate.blockUntilOpened()
                    throw CancellationError()
                }
                appliedStyles.withLock { $0.append(style) }
            }
        )
        await scene.openAndConnect()

        resolvedStyle = primaryStyle
        scene.model.terminalPresentationStyleDidChange()
        await gate.waitUntilBlocked()

        let manualDone = LockedValue(false)
        let manualApply = Task { @MainActor in
            try await scene.model.applyTheme(to: scene.selection)
            manualDone.store(true)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(manualDone.load() == false)
        #expect(appliedStyles.load().isEmpty)

        gate.open()
        try await manualApply.value
        #expect(manualDone.load() == true)
        #expect(appliedStyles.load() == [primaryStyle])

        await scene.model.shutdown()
    }

    @MainActor
    @Test("concurrent manual applies serialize so the newest style lands last")
    func concurrentManualAppliesSerialize() async throws {
        var resolvedStyle: TmuxPresentationStyle?
        let appliedStyles = LockedValue<[TmuxPresentationStyle]>([])
        let stylerCalls = LockedValue(0)
        let gate = StylerGate()
        let scene = try makeThemedScene(
            tmuxPresentationStyleProvider: { _ in resolvedStyle },
            tmuxSessionStyler: { style, _, _, _ in
                stylerCalls.withLock { $0 += 1 }
                if stylerCalls.load() == 1 {
                    await gate.blockUntilOpened()
                }
                appliedStyles.withLock { $0.append(style) }
            }
        )
        await scene.openAndConnect()

        resolvedStyle = primaryStyle
        let firstApply = Task { @MainActor in
            try await scene.model.applyTheme(to: scene.selection)
        }
        await gate.waitUntilBlocked()

        resolvedStyle = newerStyle
        let secondApply = Task { @MainActor in
            try await scene.model.applyTheme(to: scene.selection)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(appliedStyles.load().isEmpty)
        #expect(stylerCalls.load() == 1)

        gate.open()
        try await firstApply.value
        try await secondApply.value

        #expect(appliedStyles.load() == [primaryStyle, newerStyle])
        await scene.model.shutdown()
    }

    @MainActor
    @Test("a publication during a manual apply cannot start a rival ladder")
    func publicationDuringManualApplyStartsNoDeferredStyling() async throws {
        var resolvedStyle: TmuxPresentationStyle?
        let stylerCalls = LockedValue(0)
        let gate = StylerGate()
        let scene = try makeThemedScene(
            tmuxPresentationStyleProvider: { _ in resolvedStyle },
            tmuxSessionStyler: { _, _, _, _ in
                stylerCalls.withLock { $0 += 1 }
                if stylerCalls.load() == 1 {
                    await gate.blockUntilOpened()
                }
            }
        )
        await scene.openAndConnect()

        resolvedStyle = primaryStyle
        let manualApply = Task { @MainActor in
            try await scene.model.applyTheme(to: scene.selection)
        }
        await gate.waitUntilBlocked()

        // A color publication mid-apply must find the marker claimed and
        // start no deferred ladder that could race the manual command.
        scene.model.terminalPresentationStyleDidChange()
        try await Task.sleep(for: .milliseconds(50))
        #expect(stylerCalls.load() == 1)

        gate.open()
        try await manualApply.value
        try await Task.sleep(for: .milliseconds(50))

        #expect(stylerCalls.load() == 1)
        await scene.model.shutdown()
    }

    @MainActor
    @Test("a successful manual application retires the deferred ladder")
    func manualApplicationConsumesDeferredMarker() async throws {
        var resolvedStyle: TmuxPresentationStyle?
        let stylerCalls = LockedValue(0)
        let scene = try makeThemedScene(
            tmuxPresentationStyleProvider: { _ in resolvedStyle },
            tmuxSessionStyler: { _, _, _, _ in
                stylerCalls.withLock { $0 += 1 }
            }
        )
        await scene.openAndConnect()

        resolvedStyle = primaryStyle
        try await scene.model.applyTheme(to: scene.selection)
        #expect(stylerCalls.load() == 1)

        // The user has taken manual control: later color publications and
        // discovery refreshes must not restart automatic styling.
        scene.model.terminalPresentationStyleDidChange()
        scene.model.startTmuxSessionDiscovery()
        try await Task.sleep(for: .milliseconds(50))

        #expect(stylerCalls.load() == 1)
        await scene.model.shutdown()
    }

    @MainActor
    @Test("an exhausted retry ladder leaves recovery to the manual action")
    func deferredStylingGivesUpAfterExhaustedRetries() async throws {
        var resolvedStyle: TmuxPresentationStyle?
        let attempts = LockedValue(0)
        let scene = try makeThemedScene(
            deferredTmuxPresentationRetryDelays: [.milliseconds(1)],
            tmuxPresentationStyleProvider: { _ in resolvedStyle },
            tmuxSessionStyler: { _, _, _, _ in
                attempts.withLock { $0 += 1 }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: "local",
                    session: "review"
                )
            }
        )
        await scene.openAndConnect()

        resolvedStyle = primaryStyle
        scene.model.terminalPresentationStyleDidChange()
        await waitUntilMainActor(timeout: .seconds(1)) {
            attempts.load() == 2 && scene.model.tmuxStylingQuiesced
        }

        scene.model.startTmuxSessionDiscovery()
        scene.model.terminalPresentationStyleDidChange()
        try await Task.sleep(for: .milliseconds(50))

        #expect(attempts.load() == 2)
        await scene.model.shutdown()
    }
}

// MARK: - Harness

@MainActor
private struct ThemedScene {
    let model: WorkspaceSceneModel
    let store: ThemeTmuxSurfaceStoreStub
    let selection: WorkspaceTmuxSessionSelection

    func openAndConnect() async {
        model.openBorrowedTmuxSession(selection)
        await connectActiveTmuxSession(model, store: store)
    }
}

/// Builds the standard local single-host scene the styling tests share: a
/// surface with identity 42, a resolvable tmux path, and a "review" session
/// selection. Tests pass only the closures they exercise.
@MainActor
private func makeThemedScene(
    stylesExistingSessions: Bool = true,
    sessionName: String = "review",
    socketName: String? = nil,
    tmuxSessionDiscovery: @escaping WorkspaceSceneModel.TmuxSessionDiscovery =
        { _ in .success([]) },
    tmuxSessionIdentityReader:
    @escaping WorkspaceSceneModel.TmuxSessionIdentityReading =
        { _, _ in sessionIdentity },
    createdSessionDiscoveryDelays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
    ],
    deferredTmuxPresentationRetryDelays: [Duration] = [
        .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2),
        .seconds(4), .seconds(8),
    ],
    terminalColorsPublisher: AnyPublisher<
        [UInt: TerminalResolvedColors], Never
    > = Empty(completeImmediately: false).eraseToAnyPublisher(),
    tmuxPresentationStyleProvider:
    @escaping (UInt?) -> TmuxPresentationStyle?,
    tmuxSessionStyler: @escaping WorkspaceSceneModel.TmuxSessionStyling =
        { _, _, _, _ in }
) throws -> ThemedScene {
    let environment = try setupHostEnvironment()
    let store = ThemeTmuxSurfaceStoreStub(surfaceIdentity: 42)
    let model = try makeModel(
        database: environment.database,
        localHostID: environment.host.id,
        snapshot: environment.snapshot,
        nativeTmuxSurfaceStore: store,
        nativeTmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
        tmuxPresentationStyleProvider: tmuxPresentationStyleProvider,
        appliesTmuxPresentationStyleToExistingSessionsProvider: {
            stylesExistingSessions
        },
        tmuxSessionDiscovery: tmuxSessionDiscovery,
        tmuxSessionIdentityReader: tmuxSessionIdentityReader,
        tmuxSessionStyler: tmuxSessionStyler,
        terminalColorsPublisher: terminalColorsPublisher,
        createdSessionDiscoveryDelays: createdSessionDiscoveryDelays,
        deferredTmuxPresentationRetryDelays:
        deferredTmuxPresentationRetryDelays
    )
    let selection = WorkspaceTmuxSessionSelection(
        hostID: environment.host.id,
        name: sessionName,
        socketName: socketName
    )
    return ThemedScene(model: model, store: store, selection: selection)
}

/// Blocks a styler like the real runner: a detached subprocess wait that task
/// cancellation cannot interrupt, released explicitly by the test.
private struct StylerGate: Sendable {
    private let started = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()

    func blockUntilOpened() async {
        started.continuation.yield()
        await Task.detached { [stream = release.stream] in
            for await _ in stream {
                break
            }
        }.value
    }

    func waitUntilBlocked() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func open() {
        release.continuation.yield()
        release.continuation.finish()
    }
}

@MainActor
private func connectActiveTmuxSession(
    _ model: WorkspaceSceneModel,
    store: ThemeTmuxSurfaceStoreStub
) async {
    await waitUntilMainActor {
        model.prepareActiveBorrowedTmuxSurface()
        return store.requestCount > 0
            && model.activeBorrowedTmuxSessionIsConnected
    }
}

@MainActor
private final class ThemeTmuxPaneSurfaceStub: NativeSessionPaneSurfacing {
    var blocksClipboardReads = false
    var launchError: Error? { nil }
    var childExitCode: UInt32?

    func registerSurfaceCloseObserver(
        id _: UUID,
        onSurfaceClosed _: @escaping (Bool, UInt32?) -> Void
    ) {}
}

@MainActor
private final class ThemeTmuxSurfaceStoreStub: NativeSessionSurfaceStoring {
    private let surface = ThemeTmuxPaneSurfaceStub()
    private(set) var requestCount = 0
    private let surfaceIdentities: [UInt?]
    private var surfaceIdentitiesByKey: [SurfaceKey: UInt] = [:]
    private var retainedKeys: Set<SurfaceKey> = []

    init(surfaceIdentity: UInt? = nil) {
        surfaceIdentities = [surfaceIdentity]
    }

    init(surfaceIdentities: [UInt?]) {
        self.surfaceIdentities = surfaceIdentities
    }

    func paneSurface(
        for key: SurfaceKey,
        configuration _: TerminalSurfaceConfiguration
    ) -> (any NativeSessionPaneSurfacing)? {
        guard !retainedKeys.contains(key) else { return surface }
        retainedKeys.insert(key)
        let identityIndex = min(requestCount, surfaceIdentities.count - 1)
        if let identity = surfaceIdentities[identityIndex] {
            surfaceIdentitiesByKey[key] = identity
        }
        requestCount += 1
        return surface
    }

    func removeSurface(for key: SurfaceKey) {
        retainedKeys.remove(key)
        surfaceIdentitiesByKey.removeValue(forKey: key)
    }

    func surfaceIdentity(for key: SurfaceKey) -> UInt? {
        surfaceIdentitiesByKey[key]
    }
}
