//
//  SidebarOutlineReloadPolicyTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import Foundation
import AppKit
import PcapPlusPlusCore
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

    @Test func multiSelectionNavigationUsesCurrentEventRow() {
        let selectedRows = IndexSet([2, 5])

        #expect(SidebarSelectionPolicy.navigationRow(
            selectedRowIndexes: selectedRows,
            selectedRow: 2,
            currentEventRow: 5
        ) == 5)
    }

    @Test func selectionNavigationFallsBackToSingleSelectedRow() {
        #expect(SidebarSelectionPolicy.navigationRow(
            selectedRowIndexes: IndexSet(integer: 3),
            selectedRow: 3,
            currentEventRow: nil
        ) == 3)
        #expect(SidebarSelectionPolicy.navigationRow(
            selectedRowIndexes: IndexSet(),
            selectedRow: -1,
            currentEventRow: nil
        ) == nil)
    }

    @MainActor
    @Test func deferredReloadPreservesSidebarScrollPositionAndSelection() async throws {
        let selectedKey = PacketSourceDomainKey(rawValue: "domain-32.example.com", isMissingDomain: false)
        let controller = SidebarViewController()
        let selectionRecorder = SidebarSelectionRecorder()
        controller.delegate = selectionRecorder
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: 240)
        controller.view.layoutSubtreeIfNeeded()

        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithDomains(count: 48),
            selectedSelection: .domain(selectedKey),
            packetMutation: .none
        ))
        controller.view.layoutSubtreeIfNeeded()

        let outlineScrollView = try #require(findOutlineScrollView(in: controller.view))
        let outlineView = try #require(outlineScrollView.documentView as? NSOutlineView)
        #expect(outlineView.selectedRow >= 0)

        outlineScrollView.contentView.scroll(to: NSPoint(x: 0, y: 520))
        outlineScrollView.reflectScrolledClipView(outlineScrollView.contentView)
        let originalY = outlineScrollView.contentView.bounds.origin.y

        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithDomains(count: 49),
            selectedSelection: .domain(selectedKey),
            packetMutation: .append(0..<1)
        ))
        try await Task.sleep(nanoseconds: 700_000_000)
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()

        #expect(originalY > 0)
        #expect(abs(outlineScrollView.contentView.bounds.origin.y - originalY) <= 1)

        selectionRecorder.selectedSelection = nil
        controller.outlineViewSelectionDidChange(Notification(
            name: NSTableView.selectionDidChangeNotification,
            object: outlineView
        ))
        #expect(selectionRecorder.selectedSelection == .domain(selectedKey))
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

    private func makeSnapshot(
        sourceListSnapshot: PacketSourceListSnapshot,
        selectedSelection: PacketSourceListSelection,
        packetMutation: PacketIngestMutation
    ) -> NetworkInspectorSnapshot {
        var base = TCPViewerWindowSnapshot.foundation
        base.packetIngestState.lastMutation = packetMutation
        let tableContent = PacketTableContent(
            displayFilter: PacketDisplayFilter(""),
            displayFilterChips: [],
            store: PacketTableRowStore(rows: [], visiblePacketRowIndexByID: [:]),
            generation: 0,
            updatePlan: .none,
            malformedPacketCount: 0
        )

        return NetworkInspectorSnapshot.make(
            base: base,
            selectedSidebar: .liveCapture,
            selectedSourceListSelection: selectedSelection,
            sourceListSnapshot: sourceListSnapshot,
            sourceListFilterText: "",
            workspaceMode: .packets,
            inspectorTab: .summary,
            isInspectorVisible: true,
            displayFilterText: "",
            packetTableContent: tableContent
        )
    }

    private func snapshotWithDomains(count: Int) -> PacketSourceListSnapshot {
        PacketSourceListTreeBuilder.makeSnapshot(
            appBuckets: [],
            domainBuckets: (0..<count).map { index in
                let displayName = String(format: "domain-%02d.example.com", index)
                return PacketSourceListTreeBuilder.DomainBucket(identity: PacketSourceDomainIdentity(
                    key: PacketSourceDomainKey(rawValue: displayName, isMissingDomain: false),
                    displayName: displayName
                ))
            }
        )
    }

    private func findOutlineScrollView(in view: NSView) -> NSScrollView? {
        allSubviews(ofType: NSScrollView.self, in: view).first { $0.documentView is NSOutlineView }
    }

    private func allSubviews<T: NSView>(ofType type: T.Type, in view: NSView) -> [T] {
        let current = (view as? T).map { [$0] } ?? []
        return view.subviews.reduce(current) { result, subview in
            result + allSubviews(ofType: type, in: subview)
        }
    }
}

private final class SidebarSelectionRecorder: SidebarViewControllerDelegate {
    var selectedSelection: PacketSourceListSelection?

    func sidebarViewController(_ controller: SidebarViewController, didSelect selection: PacketSourceListSelection?) {
        selectedSelection = selection
    }

    func sidebarViewController(_ controller: SidebarViewController, didUpdateFilterText text: String) {}

    func sidebarViewController(_ controller: SidebarViewController, didRequestPin targets: [PacketSourceListPinTarget]) {}

    func sidebarViewController(_ controller: SidebarViewController, didRequestDelete action: PacketSourceListDeletionAction) {}

    func sidebarViewController(_ controller: SidebarViewController, didRequestExport selection: PacketSourceListSelection, format: CaptureFileFormat) {}
}
