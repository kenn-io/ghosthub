import SwiftUI
import GhosthubSettings
import GhosthubWorkspace

struct TailscalePeerPickerSheet: View {
    let peers: [TailscalePeer]
    let existingAddresses: Set<String>
    let onImport: ([TailscalePeer]) -> Void
    let onCancel: () -> Void

    @State private var selectedIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Tailscale")
                .font(.title2.weight(.semibold))

            Text(
                "Select hosts to add as SSH connections."
                    + " Only SSH-capable hosts (Linux and"
                    + " macOS, and Windows) are shown."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            peerList

            buttons
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 500)
        .onAppear {
            selectedIDs = TailscalePeerImportSelection
                .defaultSelectedPeerIDs(
                    peers: peers,
                    existingAddresses: existingAddresses
                )
        }
    }

    private var normalizedExistingAddresses: Set<String> {
        TailscalePeerImportSelection.normalizedExistingAddresses(
            existingAddresses
        )
    }

    private func alreadyAdded(
        _ peer: TailscalePeer
    ) -> Bool {
        TailscalePeerImportSelection.alreadyImported(
            peer,
            normalizedExistingAddresses: normalizedExistingAddresses
        )
    }

    private var peerList: some View {
        List(peers) { peer in
            let alreadyAdded = alreadyAdded(peer)
            HStack(spacing: 10) {
                Toggle(
                    isOn: Binding(
                        get: {
                            selectedIDs.contains(peer.id)
                        },
                        set: { isOn in
                            if isOn {
                                selectedIDs.insert(peer.id)
                            } else {
                                selectedIDs.remove(peer.id)
                            }
                        }
                    )
                ) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .disabled(alreadyAdded)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(peer.hostName)
                            .font(.system(
                                size: 13,
                                weight: .semibold
                            ))
                        if alreadyAdded {
                            Text("already added")
                                .font(.system(size: 10))
                                .foregroundStyle(
                                    .secondary
                                )
                                .padding(
                                    .horizontal, 6
                                )
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(
                                        .quaternary
                                    )
                                )
                        }
                    }
                    HStack(spacing: 8) {
                        Text(peer.sshAddress)
                            .font(.system(
                                size: 11,
                                design: .monospaced
                            ))
                            .foregroundStyle(
                                .secondary
                            )
                        Text(peer.os)
                            .font(.system(size: 11))
                            .foregroundStyle(
                                .secondary
                            )
                    }
                }

                Spacer()

                Circle()
                    .fill(
                        peer.isOnline
                            ? Color.green : Color.gray
                    )
                    .frame(width: 8, height: 8)
            }
            .opacity(alreadyAdded ? 0.5 : 1.0)
        }
        .listStyle(.plain)
    }

    private var buttons: some View {
        HStack {
            Text(
                "\(selectedIDs.count) host\(selectedIDs.count == 1 ? "" : "s") selected"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: onCancel)
            Button("Import") {
                onImport(
                    TailscalePeerImportSelection.selectedPeers(
                        peers,
                        selectedIDs: selectedIDs
                    )
                )
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedIDs.isEmpty)
        }
    }
}
