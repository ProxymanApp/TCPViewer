import Foundation
import Testing
@testable import TCPViewer

struct SidebarOutlineReloadPolicyTests {

    @Test func firstRenderReloadsImmediately() {
        let next = reloadState(
            sourceListSnapshot: .empty,
            packetMutation: .none
        )

        #expect(SidebarOutlineReloadPolicy.timing(previous: nil, next: next) == .immediate)
    }

    @Test func unchangedSidebarStateDoesNotReload() {
        let previous = reloadState(
            sourceListSnapshot: .empty,
            packetMutation: .none
        )
        let next = reloadState(
            sourceListSnapshot: .empty,
            packetMutation: .append(0..<1)
        )

        #expect(SidebarOutlineReloadPolicy.timing(previous: previous, next: next) == .none)
    }

    @Test func appendedSourceListChangesAreDeferred() {
        let previous = reloadState(
            sourceListSnapshot: .empty,
            packetMutation: .none
        )
        let next = reloadState(
            sourceListSnapshot: snapshotWithApp(),
            packetMutation: .append(0..<1)
        )

        #expect(SidebarOutlineReloadPolicy.timing(previous: previous, next: next) == .deferred)
    }

    @Test func metadataSourceListChangesAreDeferred() {
        let previous = reloadState(
            sourceListSnapshot: .empty,
            packetMutation: .none
        )
        let next = reloadState(
            sourceListSnapshot: snapshotWithApp(),
            packetMutation: .metadataUpdate(packetIDs: [])
        )

        #expect(SidebarOutlineReloadPolicy.timing(previous: previous, next: next) == .deferred)
    }

    @Test func filterAndSelectionChangesReloadImmediately() {
        let previous = reloadState(
            sourceListSnapshot: snapshotWithApp(),
            packetMutation: .append(0..<1)
        )
        let filtered = reloadState(
            sourceListSnapshot: snapshotWithApp(),
            filterText: "chrome",
            packetMutation: .append(1..<2)
        )
        let selected = reloadState(
            sourceListSnapshot: snapshotWithApp(),
            selectedSelection: .app(PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.App")),
            packetMutation: .append(1..<2)
        )

        #expect(SidebarOutlineReloadPolicy.timing(previous: previous, next: filtered) == .immediate)
        #expect(SidebarOutlineReloadPolicy.timing(previous: previous, next: selected) == .immediate)
    }

    @Test func resetAndReplaceSourceListChangesReloadImmediately() {
        let previous = reloadState(
            sourceListSnapshot: snapshotWithApp(),
            packetMutation: .append(0..<1)
        )
        let reset = reloadState(
            sourceListSnapshot: .empty,
            packetMutation: .reset
        )
        let replaced = reloadState(
            sourceListSnapshot: snapshotWithDomain(),
            packetMutation: .replace
        )

        #expect(SidebarOutlineReloadPolicy.timing(previous: previous, next: reset) == .immediate)
        #expect(SidebarOutlineReloadPolicy.timing(previous: previous, next: replaced) == .immediate)
    }

    private func reloadState(
        sourceListSnapshot: PacketSourceListSnapshot,
        filterText: String = "",
        selectedSelection: PacketSourceListSelection = .allPackets,
        packetMutation: PacketIngestMutation
    ) -> SidebarOutlineReloadState {
        SidebarOutlineReloadState(
            sourceListSnapshot: sourceListSnapshot,
            filterText: filterText,
            selectedSelection: selectedSelection,
            packetMutation: packetMutation
        )
    }

    private func snapshotWithApp() -> PacketSourceListSnapshot {
        PacketSourceListTreeBuilder.makeSnapshot(
            appBuckets: [
                PacketSourceListTreeBuilder.AppBucket(identity: PacketSourceClientIdentity(
                    key: PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.App"),
                    displayName: "Example",
                    iconFilePath: nil
                )),
            ],
            domainBuckets: []
        )
    }

    private func snapshotWithDomain() -> PacketSourceListSnapshot {
        PacketSourceListTreeBuilder.makeSnapshot(
            appBuckets: [],
            domainBuckets: [
                PacketSourceListTreeBuilder.DomainBucket(identity: PacketSourceDomainIdentity(
                    key: PacketSourceDomainKey(rawValue: "example.com", isMissingDomain: false),
                    displayName: "example.com"
                )),
            ]
        )
    }
}
