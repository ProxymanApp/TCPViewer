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

    @MainActor
    @Test func deferredReloadDoesNotScrollSelectedFavoriteBackIntoView() async throws {
        let pin = pinnedClient()
        let controller = SidebarViewController()
        let selectionRecorder = SidebarSelectionRecorder()
        controller.delegate = selectionRecorder
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: 240)
        controller.view.layoutSubtreeIfNeeded()

        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithPinnedClient(pin, count: 1, domainCount: 64),
            selectedSelection: .pinnedItem(pin.id),
            packetMutation: .none
        ))
        controller.view.layoutSubtreeIfNeeded()

        let outlineScrollView = try #require(findOutlineScrollView(in: controller.view))
        let outlineView = try #require(outlineScrollView.documentView as? NSOutlineView)
        let selectedRow = outlineView.selectedRow
        #expect(selectedRow >= 0)

        outlineScrollView.contentView.scroll(to: NSPoint(x: 0, y: 520))
        outlineScrollView.reflectScrolledClipView(outlineScrollView.contentView)
        let originalY = outlineScrollView.contentView.bounds.origin.y
        #expect(outlineView.rect(ofRow: selectedRow).maxY < originalY)

        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithPinnedClient(pin, count: 2, domainCount: 65),
            selectedSelection: .pinnedItem(pin.id),
            packetMutation: .append(0..<1)
        ))
        try await Task.sleep(nanoseconds: 700_000_000)
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()

        #expect(originalY > 0)
        #expect(abs(outlineScrollView.contentView.bounds.origin.y - originalY) <= 1)
        #expect(outlineView.selectedRow >= 0)
    }

    @MainActor
    @Test func deferredReloadKeepsVisibleSelectionAnchoredWhenRowsAreInsertedAbove() async throws {
        let selectedKey = PacketSourceDomainKey(rawValue: "domain-20.example.com", isMissingDomain: false)
        let controller = SidebarViewController()
        let selectionRecorder = SidebarSelectionRecorder()
        controller.delegate = selectionRecorder
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: 240)
        controller.view.layoutSubtreeIfNeeded()

        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithAppsAndDomains(appCount: 1, domainCount: 48),
            selectedSelection: .domain(selectedKey),
            packetMutation: .none
        ))
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()

        let outlineScrollView = try #require(findOutlineScrollView(in: controller.view))
        let outlineView = try #require(outlineScrollView.documentView as? NSOutlineView)
        let selectedRow = outlineView.selectedRow
        #expect(selectedRow >= 0)

        let selectedOffsetY: CGFloat = 6
        let selectedOrigin = outlineView.rect(ofRow: selectedRow).minY - selectedOffsetY
        outlineScrollView.contentView.scroll(to: NSPoint(x: 0, y: selectedOrigin))
        outlineScrollView.reflectScrolledClipView(outlineScrollView.contentView)
        let originalY = outlineScrollView.contentView.bounds.origin.y
        let originalSelectedOffset = outlineView.rect(ofRow: selectedRow).minY - originalY
        selectionRecorder.selectedSelections.removeAll()

        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithAppsAndDomains(appCount: 16, domainCount: 48),
            selectedSelection: .domain(selectedKey),
            packetMutation: .append(0..<1)
        ))
        try await Task.sleep(nanoseconds: 700_000_000)
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()

        let updatedSelectedRow = outlineView.selectedRow
        #expect(updatedSelectedRow > selectedRow)
        #expect(outlineScrollView.contentView.bounds.origin.y > originalY)
        #expect(abs((outlineView.rect(ofRow: updatedSelectedRow).minY - outlineScrollView.contentView.bounds.origin.y) - originalSelectedOffset) <= 1)
        #expect(selectionRecorder.selectedSelections.isEmpty)
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

    private func snapshotWithAppsAndDomains(appCount: Int, domainCount: Int) -> PacketSourceListSnapshot {
        PacketSourceListTreeBuilder.makeSnapshot(
            appBuckets: (0..<appCount).map { index in
                PacketSourceListTreeBuilder.AppBucket(identity: PacketSourceClientIdentity(
                    key: PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.App\(index)"),
                    displayName: String(format: "Example %02d", index),
                    iconFilePath: nil
                ))
            },
            domainBuckets: domainBuckets(count: domainCount)
        )
    }

    private func pinnedClient() -> PacketPin {
        PacketPin(
            id: PacketPinID(rawValue: "client:bundleIdentifier:com.example.App"),
            kind: .client,
            title: "Example",
            createdAt: Date(timeIntervalSince1970: 1),
            domain: nil,
            ipAddress: nil,
            clientKey: "bundleIdentifier:com.example.App",
            clientDisplayName: "Example",
            clientIconFilePath: nil
        )
    }

    private func snapshotWithPinnedClient(_ pin: PacketPin, count: Int, domainCount: Int) -> PacketSourceListSnapshot {
        var appBucket = PacketSourceListTreeBuilder.AppBucket(identity: PacketSourceClientIdentity(
            key: PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.App"),
            displayName: "Example",
            iconFilePath: nil
        ))
        for index in 0..<count {
            appBucket.increment(
                domainIdentity: PacketSourceDomainIdentity(
                    key: PacketSourceDomainKey(rawValue: "favorite-\(index).example.com", isMissingDomain: false),
                    displayName: "favorite-\(index).example.com"
                ),
                ipAddressIdentities: []
            )
        }

        return PacketSourceListTreeBuilder.makeSnapshot(
            appBuckets: [appBucket],
            domainBuckets: (0..<domainCount).map { index in
                let displayName = String(format: "domain-%02d.example.com", index)
                return PacketSourceListTreeBuilder.DomainBucket(identity: PacketSourceDomainIdentity(
                    key: PacketSourceDomainKey(rawValue: displayName, isMissingDomain: false),
                    displayName: displayName
                ))
            },
            pinnedBuckets: [
                PacketSourceListTreeBuilder.PinnedBucket(
                    pin: pin,
                    packetCount: count,
                    domainBuckets: appBucket.orderedDomainBuckets,
                    ipAddressBuckets: []
                ),
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
            domainBuckets: domainBuckets(count: count)
        )
    }

    private func domainBuckets(count: Int) -> [PacketSourceListTreeBuilder.DomainBucket] {
        (0..<count).map { index in
            let displayName = String(format: "domain-%02d.example.com", index)
            return PacketSourceListTreeBuilder.DomainBucket(identity: PacketSourceDomainIdentity(
                key: PacketSourceDomainKey(rawValue: displayName, isMissingDomain: false),
                displayName: displayName
            ))
        }
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
    var selectedSelections: [PacketSourceListSelection?] = []

    func sidebarViewController(_ controller: SidebarViewController, didSelect selection: PacketSourceListSelection?) {
        selectedSelection = selection
        selectedSelections.append(selection)
    }

    func sidebarViewController(_ controller: SidebarViewController, didUpdateFilterText text: String) {}

    func sidebarViewController(_ controller: SidebarViewController, didRequestPin targets: [PacketSourceListPinTarget]) {}

    func sidebarViewController(_ controller: SidebarViewController, didRequestDelete action: PacketSourceListDeletionAction) {}

    func sidebarViewController(_ controller: SidebarViewController, didRequestExport selection: PacketSourceListSelection, format: CaptureFileFormat) {}
}
