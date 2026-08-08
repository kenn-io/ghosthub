import Foundation
import Testing
@testable import GhosthubWorkspace

struct SurfaceKeyTests {
    let hostID = UUID()
    let worktreeID = UUID()

    @Test("equal keys compare equal and share a hash")
    func equalKeysAreEqual() {
        let a = SurfaceKey.fixture(
            worktreeID: worktreeID,
            hostID: hostID
        )
        let b = SurfaceKey.fixture(
            worktreeID: worktreeID,
            hostID: hostID
        )

        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("different targets are not equal")
    func differentTargetsAreNotEqual() {
        let shell = SurfaceKey.fixture(
            worktreeID: worktreeID,
            hostID: hostID,
            target: .worktreeShell
        )
        let assistant = SurfaceKey.fixture(
            worktreeID: worktreeID,
            hostID: hostID,
            target: .worktreeAssistant
        )

        #expect(shell != assistant)
    }

    @Test("different worktree ids are not equal")
    func differentWorktreeIDsAreNotEqual() {
        let a = SurfaceKey.fixture(hostID: hostID)
        let b = SurfaceKey.fixture(hostID: hostID)

        #expect(a != b)
    }

    @Test("console keys may compare equal with a nil worktree id")
    func nilWorktreeIDForConsole() {
        let a = SurfaceKey.consoleFixture(hostID: hostID)
        let b = SurfaceKey.consoleFixture(hostID: hostID)

        #expect(a == b)
    }

    @Test("different host ids are not equal")
    func differentHostIDsAreNotEqual() {
        let a = SurfaceKey.consoleFixture()
        let b = SurfaceKey.consoleFixture()

        #expect(a != b)
    }

    @Test("surface keys can be used as dictionary keys")
    func canBeUsedAsDictionaryKey() {
        let key = SurfaceKey.fixture()

        var dict: [SurfaceKey: String] = [:]
        dict[key] = "test"
        #expect(dict[key] == "test")
    }

    @Test("workspace terminal surface target typealias remains compatible")
    func typealiasBackwardCompatibility() {
        let target: WorkspaceTerminalSurfaceTarget = .worktreeShell
        let converted: TerminalSurfaceTarget = target
        #expect(converted == .worktreeShell)
    }

    @Test("scoped key includes host worktree target and leaf")
    func scopedKeyIncludesHostWorktreeTargetAndLeaf() {
        let leafID = UUID()
        let key = SurfaceKey.fixture(
            worktreeID: worktreeID,
            hostID: hostID,
            target: .worktreeShell,
            leafID: leafID
        )

        let expected = "surface:"
            + "\(hostID.uuidString):"
            + "\(worktreeID.uuidString):"
            + "worktreeShell:"
            + leafID.uuidString
        #expect(
            key.scopedKey == expected
        )
    }

    @Test("scoped key uses console and root sentinels")
    func scopedKeyUsesConsoleAndRootSentinels() {
        let key = SurfaceKey.consoleFixture(hostID: hostID)

        #expect(
            key.scopedKey ==
                "surface:\(hostID.uuidString):console:console:root"
        )
    }

    @Test("Herdr session keys have their own surface target")
    func herdrSessionSurfaceTarget() {
        let key = SurfaceKey(
            worktreeID: nil,
            hostID: hostID,
            target: .herdrSession
        )

        #expect(
            key.scopedKey
                == "surface:\(hostID.uuidString):console:herdrSession:root"
        )
    }
}
