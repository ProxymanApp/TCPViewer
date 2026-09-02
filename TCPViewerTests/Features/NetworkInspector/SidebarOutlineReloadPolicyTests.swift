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

    @Test func scrollPositionPolicyClampsNegativeTitlebarInsetOrigins() {
        let negativeOrigin = SidebarOutlineScrollPositionPolicy.normalized(origin: NSPoint(x: 0, y: -44))
        let validOrigin = SidebarOutlineScrollPositionPolicy.normalized(origin: NSPoint(x: 0, y: 96))

        #expect(negativeOrigin.y == 0)
        #expect(validOrigin.y == 96)
    }

    @MainActor
    @Test func sidebarScrollViewDisablesAutomaticTitlebarInsets() throws {
        let controller = SidebarViewController()
        controller.loadViewIfNeeded()

        let outlineScrollView = try #require(findOutlineScrollView(in: controller.view))
        #expect(!outlineScrollView.automaticallyAdjustsContentInsets)
        #expect(outlineScrollView.contentInsets.top == 0)
    }

    @MainActor
    @Test func sidebarFilterPlaceholderShowsGlobalShortcut() throws {
        let controller = SidebarViewController()
        controller.loadViewIfNeeded()

        let searchField = try #require(allSubviews(ofType: NSSearchField.self, in: controller.view).first)
        #expect(searchField.placeholderString == "Filter (⌘⇧F)")
    }

    @MainActor
    @Test func captureOverviewIsFirstInitiallyExpandedAndHasNoPacketContextActions() async throws {
        let controller = SidebarViewController()
        let selectionRecorder = SidebarSelectionRecorder()
        controller.delegate = selectionRecorder
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: PacketSourceListSnapshot.empty.filtered(matching: "no-match"),
            selectedSelection: .allPackets,
            packetMutation: .none,
            filterText: "no-match",
            workspaceMode: .overview
        ))

        let outlineView = try #require(findOutlineScrollView(in: controller.view)?.documentView as? NSOutlineView)
        let captureRow = try #require(row(withItemID: PacketSourceListTreeBuilder.captureGroupID, in: outlineView))
        let overviewRow = try #require(row(withItemID: PacketSourceListTreeBuilder.overviewItemID, in: outlineView))
        let captureItem = try #require(outlineView.item(atRow: captureRow))
        let menu = try #require(outlineView.menu)

        #expect(captureRow == 0)
        #expect(outlineView.isItemExpanded(captureItem))
        #expect(outlineView.selectedRow == overviewRow)

        await Task.yield()
        controller.outlineViewSelectionDidChange(Notification(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outlineView
        ))
        controller.menuNeedsUpdate(menu)

        #expect(selectionRecorder.selectedWorkspaceModes == [.overview])
        #expect(menu.items.isEmpty)
    }

    @MainActor
    @Test func collapsedCaptureGroupStaysCollapsedAfterSidebarRefresh() throws {
        let controller = SidebarViewController()
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: .empty,
            selectedSelection: .allPackets,
            packetMutation: .none
        ))

        let outlineView = try #require(findOutlineScrollView(in: controller.view)?.documentView as? NSOutlineView)
        let captureRow = try #require(row(withItemID: PacketSourceListTreeBuilder.captureGroupID, in: outlineView))
        let captureItem = try #require(outlineView.item(atRow: captureRow))
        outlineView.collapseItem(captureItem)
        #expect(!outlineView.isItemExpanded(captureItem))

        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithApp(),
            selectedSelection: .allPackets,
            packetMutation: .replace
        ))

        let refreshedCaptureRow = try #require(row(withItemID: PacketSourceListTreeBuilder.captureGroupID, in: outlineView))
        let refreshedCaptureItem = try #require(outlineView.item(atRow: refreshedCaptureRow))
        #expect(!outlineView.isItemExpanded(refreshedCaptureItem))
        #expect(row(withItemID: PacketSourceListTreeBuilder.overviewItemID, in: outlineView) == nil)
    }

    @MainActor
    @Test func repeatedStartupRendersKeepDefaultGroupsExpanded() throws {
        let controller = SidebarViewController()
        controller.loadViewIfNeeded()
        let startupSnapshot = makeSnapshot(
            sourceListSnapshot: .empty,
            selectedSelection: .allPackets,
            packetMutation: .none
        )

        controller.render(snapshot: startupSnapshot)
        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithApp(),
            selectedSelection: .allPackets,
            packetMutation: .replace
        ))

        let outlineView = try #require(findOutlineScrollView(in: controller.view)?.documentView as? NSOutlineView)
        for itemID in [
            PacketSourceListTreeBuilder.captureGroupID,
            PacketSourceListTreeBuilder.favoritesGroupID,
            PacketSourceListTreeBuilder.allGroupID,
            PacketSourceListTreeBuilder.pinnedFolderID,
            PacketSourceListTreeBuilder.appsFolderID,
            PacketSourceListTreeBuilder.domainsFolderID,
        ] {
            let itemRow = try #require(row(withItemID: itemID, in: outlineView))
            let item = try #require(outlineView.item(atRow: itemRow))
            #expect(outlineView.isItemExpanded(item))
        }
    }

    @MainActor
    @Test func firstWindowAppearanceRestoresDefaultGroupsAfterAppKitCollapsesThem() throws {
        let controller = SidebarViewController()
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithApp(),
            selectedSelection: .allPackets,
            packetMutation: .none
        ))

        let outlineView = try #require(findOutlineScrollView(in: controller.view)?.documentView as? NSOutlineView)
        for itemID in [
            PacketSourceListTreeBuilder.captureGroupID,
            PacketSourceListTreeBuilder.favoritesGroupID,
            PacketSourceListTreeBuilder.allGroupID,
        ] {
            let itemRow = try #require(row(withItemID: itemID, in: outlineView))
            outlineView.collapseItem(outlineView.item(atRow: itemRow))
        }

        let window = NSWindow(contentViewController: controller)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        controller.viewDidAppear()

        for itemID in [
            PacketSourceListTreeBuilder.captureGroupID,
            PacketSourceListTreeBuilder.favoritesGroupID,
            PacketSourceListTreeBuilder.allGroupID,
            PacketSourceListTreeBuilder.pinnedFolderID,
            PacketSourceListTreeBuilder.appsFolderID,
            PacketSourceListTreeBuilder.domainsFolderID,
        ] {
            let itemRow = try #require(row(withItemID: itemID, in: outlineView))
            let item = try #require(outlineView.item(atRow: itemRow))
            #expect(outlineView.isItemExpanded(item))
        }
    }

    @MainActor
    @Test func revealingEndpointAppExpandsAncestorsAndSelectsItsRow() throws {
        let appKey = PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.App")
        let controller = SidebarViewController()
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithApp(),
            selectedSelection: .saved,
            packetMutation: .none
        ))

        let outlineView = try #require(findOutlineScrollView(in: controller.view)?.documentView as? NSOutlineView)
        let allRow = try #require(row(withItemID: PacketSourceListTreeBuilder.allGroupID, in: outlineView))
        let allItem = try #require(outlineView.item(atRow: allRow))
        outlineView.collapseItem(allItem)

        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithApp(),
            selectedSelection: .app(appKey),
            packetMutation: .replace
        ))
        controller.revealSourceListSelection(.app(appKey))

        let appRow = try #require(row(withItemID: "app:\(appKey.rawValue)", in: outlineView))
        let refreshedAllRow = try #require(row(withItemID: PacketSourceListTreeBuilder.allGroupID, in: outlineView))
        let refreshedAllItem = try #require(outlineView.item(atRow: refreshedAllRow))
        let appsRow = try #require(row(withItemID: PacketSourceListTreeBuilder.appsFolderID, in: outlineView))
        let appsItem = try #require(outlineView.item(atRow: appsRow))
        #expect(outlineView.isItemExpanded(refreshedAllItem))
        #expect(outlineView.isItemExpanded(appsItem))
        #expect(outlineView.selectedRow == appRow)
    }

    @MainActor
    @Test func sidebarContextMenuPlacesPinFirstAndShowInFinderAboveDelete() throws {
        let appKey = PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.App")
        let controller = SidebarViewController()
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithFinderApp(),
            selectedSelection: .app(appKey),
            packetMutation: .none
        ))

        let outlineView = try #require(findOutlineScrollView(in: controller.view)?.documentView as? NSOutlineView)
        let menu = try #require(outlineView.menu)
        #expect(outlineView.selectedRow >= 0)

        controller.menuNeedsUpdate(menu)

        let nonSeparatorTitles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(nonSeparatorTitles == ["Pin", "Copy App Name", "Export", "Show in Finder…", "Delete"])
        let pinIndex = try #require(menu.items.firstIndex { $0.title == "Pin" })
        #expect(pinIndex == 0)
        #expect(menu.items[pinIndex + 1].isSeparatorItem)
        let copyIndex = try #require(menu.items.firstIndex { $0.title == "Copy App Name" })
        #expect(menu.items[copyIndex + 1].isSeparatorItem)
        let finderIndex = try #require(menu.items.firstIndex { $0.title == "Show in Finder…" })
        let deleteIndex = try #require(menu.items.firstIndex { $0.title == "Delete" })
        #expect(deleteIndex == finderIndex + 2)
        #expect(menu.items[finderIndex + 1].isSeparatorItem)
    }

    @MainActor
    @Test func sidebarContextMenuUsesDomainCopyTitleForDomainRows() throws {
        let domainKey = PacketSourceDomainKey(rawValue: "example.com", isMissingDomain: false)
        let controller = SidebarViewController()
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshotWithDomain(),
            selectedSelection: .domain(domainKey),
            packetMutation: .none
        ))

        let outlineView = try #require(findOutlineScrollView(in: controller.view)?.documentView as? NSOutlineView)
        let menu = try #require(outlineView.menu)
        #expect(outlineView.selectedRow >= 0)

        controller.menuNeedsUpdate(menu)

        let nonSeparatorTitles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(nonSeparatorTitles.first == "Pin")
        #expect(nonSeparatorTitles.contains("Copy Domain Name"))
        #expect(!nonSeparatorTitles.contains("Copy App Name"))
    }

    @MainActor
    @Test func selectingImportedFileExpandsFilesGroupAndSelectsFileRow() async throws {
        let fileID = ImportedCaptureFileID(rawValue: "/tmp/sidebar-import.pcapng")
        let snapshot = snapshotWithImportedFile(fileID: fileID, displayName: "sidebar-import.pcapng")
        let controller = SidebarViewController()
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshot,
            selectedSelection: .allPackets,
            packetMutation: .none
        ))
        controller.view.layoutSubtreeIfNeeded()

        let outlineView = try #require(findOutlineScrollView(in: controller.view)?.documentView as? NSOutlineView)
        let filesRow = try #require(row(withItemID: PacketSourceListTreeBuilder.filesGroupID, in: outlineView))
        let filesItem = try #require(outlineView.item(atRow: filesRow))
        let fileItemID = try #require(snapshot.item(for: .file(fileID))?.id)
        outlineView.collapseItem(filesItem)
        #expect(row(withItemID: fileItemID, in: outlineView) == nil)

        controller.render(snapshot: makeSnapshot(
            sourceListSnapshot: snapshot,
            selectedSelection: .file(fileID),
            packetMutation: .replace
        ))
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()

        let fileRow = try #require(row(withItemID: fileItemID, in: outlineView))
        let updatedFilesRow = try #require(row(withItemID: PacketSourceListTreeBuilder.filesGroupID, in: outlineView))
        let updatedFilesItem = try #require(outlineView.item(atRow: updatedFilesRow))
        #expect(outlineView.isItemExpanded(updatedFilesItem))
        #expect(outlineView.selectedRow == fileRow)
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

    private func snapshotWithFinderApp() -> PacketSourceListSnapshot {
        var appBucket = PacketSourceListTreeBuilder.AppBucket(identity: PacketSourceClientIdentity(
            key: PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.App"),
            displayName: "Example",
            iconFilePath: "/Applications/Example.app"
        ))
        appBucket.increment(
            domainIdentity: PacketSourceDomainIdentity(
                key: PacketSourceDomainKey(rawValue: "example.com", isMissingDomain: false),
                displayName: "example.com"
            ),
            ipAddressIdentities: []
        )

        return PacketSourceListTreeBuilder.makeSnapshot(
            appBuckets: [appBucket],
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

    private func snapshotWithImportedFile(fileID: ImportedCaptureFileID, displayName: String) -> PacketSourceListSnapshot {
        let file = ImportedCaptureFile(
            id: fileID,
            url: URL(fileURLWithPath: fileID.rawValue),
            displayName: displayName,
            packetIDs: []
        )
        return PacketSourceListTreeBuilder.makeSnapshot(
            appBuckets: [],
            domainBuckets: [],
            importedFileBuckets: [PacketSourceListTreeBuilder.ImportedFileBucket(file: file)]
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
        packetMutation: PacketIngestMutation,
        filterText: String = "",
        workspaceMode: NetworkInspectorWorkspaceMode = .packets
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
            sourceListFilterText: filterText,
            workspaceMode: workspaceMode,
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

    private func row(withItemID itemID: String, in outlineView: NSOutlineView) -> Int? {
        for row in 0..<outlineView.numberOfRows {
            guard sourceListItem(at: row, in: outlineView)?.id == itemID else {
                continue
            }

            return row
        }

        return nil
    }

    private func sourceListItem(at row: Int, in outlineView: NSOutlineView) -> PacketSourceListItem? {
        guard let outlineItem = outlineView.item(atRow: row) else {
            return nil
        }

        return Mirror(reflecting: outlineItem)
            .children
            .first { $0.label == "sourceItem" }?
            .value as? PacketSourceListItem
    }
}

private final class SidebarSelectionRecorder: SidebarViewControllerDelegate {
    var selectedSelection: PacketSourceListSelection?
    var selectedSelections: [PacketSourceListSelection?] = []
    var selectedWorkspaceModes: [NetworkInspectorWorkspaceMode] = []

    func sidebarViewController(_ controller: SidebarViewController, didSelect selection: PacketSourceListSelection?) {
        selectedSelection = selection
        selectedSelections.append(selection)
    }

    func sidebarViewController(
        _ controller: SidebarViewController,
        didSelectWorkspaceMode mode: NetworkInspectorWorkspaceMode
    ) {
        selectedWorkspaceModes.append(mode)
    }

    func sidebarViewController(_ controller: SidebarViewController, didUpdateFilterText text: String) {}

    func sidebarViewController(_ controller: SidebarViewController, didRequestPin targets: [PacketSourceListPinTarget]) {}

    func sidebarViewController(_ controller: SidebarViewController, didRequestDelete action: PacketSourceListDeletionAction) {}

    func sidebarViewController(_ controller: SidebarViewController, didRequestExport selection: PacketSourceListSelection, format: CaptureFileFormat) {}
}
