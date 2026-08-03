import Testing
@testable import GhosthubSettings

struct TailscalePeerImportSelectionTests {
    @Test("normalizes user-qualified SSH destinations")
    func normalizesUserQualifiedSSHDestinations() {
        #expect(
            TailscalePeerImportSelection.normalizedHost(
                "dev@box.tailnet.ts.net"
            ) == "box.tailnet.ts.net"
        )
        #expect(
            TailscalePeerImportSelection.normalizedHost(
                "box.tailnet.ts.net"
            ) == "box.tailnet.ts.net"
        )
    }

    @Test("marks existing peers after normalizing SSH destinations")
    func marksExistingPeersAfterNormalizingSSHDestinations() {
        let peer = makePeer(
            id: "box",
            hostName: "box",
            dnsName: "box.tailnet.ts.net."
        )

        #expect(
            TailscalePeerImportSelection.alreadyImported(
                peer,
                existingAddresses: ["wes@box.tailnet.ts.net"]
            )
        )
    }

    @Test("default selection includes only online peers not already imported")
    func defaultSelectionIncludesOnlyOnlineNewPeers() {
        let selectedIDs =
            TailscalePeerImportSelection.defaultSelectedPeerIDs(
                peers: [
                    makePeer(id: "online", hostName: "online"),
                    makePeer(
                        id: "offline",
                        hostName: "offline",
                        isOnline: false
                    ),
                    makePeer(id: "existing", hostName: "existing"),
                ],
                existingAddresses: [
                    "git@existing.tailnet.ts.net",
                ]
            )

        #expect(selectedIDs == ["online"])
    }

    @Test("selected peers preserve discovery order")
    func selectedPeersPreserveDiscoveryOrder() {
        let first = makePeer(id: "first", hostName: "first")
        let second = makePeer(id: "second", hostName: "second")
        let third = makePeer(id: "third", hostName: "third")

        #expect(
            TailscalePeerImportSelection.selectedPeers(
                [first, second, third],
                selectedIDs: ["third", "first"]
            ) == [first, third]
        )
    }

    private func makePeer(
        id: String,
        hostName: String,
        dnsName: String? = nil,
        isOnline: Bool = true
    ) -> TailscalePeer {
        TailscalePeer(
            id: id,
            hostName: hostName,
            dnsName: dnsName ?? "\(hostName).tailnet.ts.net.",
            os: "linux",
            isOnline: isOnline,
            sshUsername: nil
        )
    }
}
