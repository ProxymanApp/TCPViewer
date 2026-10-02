//
//  DiffPoolModelTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import AppKit
import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

@MainActor @Suite(.serialized)
struct DiffPoolModelTests {
    @Test func initialBatchDeduplicatesAndSelectsFirstTwoInOrder() {
        let model = makeModel()
        let a = entry(1), b = entry(2), c = entry(3)
        model.add([(a, loading), (a, loading), (b, loading), (c, loading)])
        #expect(model.entries.map(\.id) == [a.id, b.id, c.id])
        #expect(model.left === a)
        #expect(model.right === b)
        #expect(c.side == nil)
    }

    @Test func freeBatchAddsOnlyFirstTwoUniqueItemsAndSelectsBothSides() {
        let model = makeModel()
        let batch = (1...10).reversed().map { entry(UInt64($0)) }
        let rejected = model.add(batch.map { ($0, loading) }, isLicenseAuthorized: false)
        #expect(rejected == 8)
        #expect(model.entries.map(\.id) == Array(batch.prefix(2)).map(\.id))
        #expect(model.left === batch[0] && model.right === batch[1])
    }

    @Test func freeLimitCountsExistingItemsAndIgnoresRepeatedAdditions() {
        let model = makeModel()
        let a = entry(1), b = entry(2), c = entry(3)
        #expect(model.add([(a, loading)], isLicenseAuthorized: false) == 0)
        let rejected = model.add([(entry(1), loading), (b, loading), (c, loading), (entry(3), loading)], isLicenseAuthorized: false)
        #expect(rejected == 1)
        #expect(model.entries.map(\.id) == [a.id, b.id])
        #expect(model.left === a && model.right === b)
        model.assign(nil, to: a.id)
        #expect(model.add([(entry(1), loading), (entry(2), loading)], isLicenseAuthorized: false) == 0)
        #expect(model.left == nil && model.right === b)
    }

    @Test func freeLimitCountsCrossCaptureItemsAndRemovalFreesCapacity() {
        let model = makeModel()
        let a = entry(1), b = entry(1, capture: UUID()), c = entry(1, lineage: 2)
        #expect(model.add([(a, loading), (b, loading), (c, loading)], isLicenseAuthorized: false) == 1)
        model.remove([a.id])
        #expect(model.add([(c, loading)], isLicenseAuthorized: false) == 0)
        #expect(model.entries.map(\.id) == [b.id, c.id])
        model.removeAll()
        #expect(model.add([(a, loading), (b, loading)], isLicenseAuthorized: false) == 0)
        #expect(model.left === a && model.right === b)
    }

    @Test func proAllowsUnlimitedAdditionsAndLicenseChangesApplyOnNextAdd() {
        let model = makeModel()
        let batch = (1...10).map { entry(UInt64($0)) }
        #expect(model.add(Array(batch.prefix(3)).map { ($0, loading) }, isLicenseAuthorized: false) == 1)
        #expect(model.add(batch.map { ($0, loading) }, isLicenseAuthorized: true) == 0)
        #expect(model.entries.count == 10)
        #expect(model.left === batch[0] && model.right === batch[1])
        #expect(model.add([(entry(11), loading)], isLicenseAuthorized: false) == 1)
        #expect(model.entries.count == 10)
    }

    @Test func freeLimitNeverQueuesRejectedInspections() async {
        let model = makeModel()
        var inspected: [UInt64] = []
        let additions: [(DiffPacketEntry, DiffPoolModel.Inspect)] = (1...10).map { number in
            let id = UInt64(number)
            return (entry(id), { completion in
                inspected.append(id)
                completion(.success(inspection(id, value: "synthetic")))
            })
        }
        #expect(model.add(additions, isLicenseAuthorized: false) == 8)
        await waitFor { model.right?.text != nil }
        #expect(inspected == [1, 2])
    }

    @Test(arguments: [1, 2]) func partialBatchAlertExplainsLimitAndOffersPaywall(addedCount: Int) {
        let alert = AppDelegate.makeDiffLimitAlert(addedCount: addedCount)
        #expect(alert.messageText == "The Free version allows 2 Diff items")
        #expect(alert.informativeText.contains(addedCount == 1 ? "1 item was added." : "The first 2 items were added."))
        #expect(alert.informativeText.contains("unlimited items in the Diff pool"))
        #expect(alert.buttons.map(\.title) == ["Upgrade to PRO", "Not Now"])
    }

    @Test func addingSecondEntryFillsRightButLaterAddsPreserveChoice() {
        let model = makeModel()
        let a = entry(1), b = entry(2), c = entry(3)
        model.add([(a, loading)])
        #expect(model.left === a && model.right == nil)
        model.add([(b, loading)])
        #expect(model.right === b)
        model.assign(.left, to: b.id)
        model.add([(c, loading)])
        #expect(model.left === b && model.right == nil)
        #expect(a.side == nil && c.side == nil)
    }

    @Test func clearedSidesInLargerPoolStayEmpty() {
        let model = makeModel()
        let a = entry(1), b = entry(2)
        model.add([(a, loading), (b, loading)])
        model.assign(nil, to: a.id)
        model.assign(nil, to: b.id)
        model.add([(entry(3), loading)])
        #expect(model.left == nil && model.right == nil)
    }

    @Test func sideAssignmentIsExclusiveAndRemovalKeepsSurvivingSide() {
        let model = makeModel()
        let a = entry(1), b = entry(2), c = entry(3)
        model.add([(a, loading), (b, loading), (c, loading)])
        model.assign(.left, to: c.id)
        #expect(a.side == nil && model.left === c)
        model.assign(.right, to: c.id)
        #expect(model.left == nil && model.right === c && b.side == nil)
        model.assign(.left, to: a.id)
        model.remove([c.id])
        #expect(model.left === a && model.right == nil)
        model.removeAll()
        #expect(model.entries.isEmpty && model.left == nil && model.right == nil)
    }

    @Test func captureAndLineageSeparateEqualPacketIDs() {
        let model = makeModel()
        let a = entry(1), b = entry(1, capture: UUID()), c = entry(1, lineage: 2)
        model.add([(a, loading), (b, loading), (c, loading)])
        #expect(model.entries.count == 3)
    }

    @Test func inspectionsAreSerialAndRemovedEntryCannotOverwriteItsReplacement() async {
        let model = makeModel()
        let a = entry(1), replacement = entry(1), b = entry(2)
        var callbacks: [TCPViewerCompletion<PacketInspection>] = []
        let inspect: DiffPoolModel.Inspect = { callbacks.append($0) }
        model.add([(a, inspect), (b, inspect)])
        #expect(callbacks.count == 1)
        model.remove([a.id])
        model.add([(replacement, inspect)])
        callbacks[0](.success(inspection(1, value: "old", bytes: Data([0xFF]))))
        await waitFor { callbacks.count == 2 }
        #expect(replacement.text == nil && replacement.bytes == nil)
        callbacks[1](.success(inspection(2, value: "second")))
        await waitFor { callbacks.count == 3 }
        callbacks[2](.success(inspection(1, value: "replacement", bytes: Data([0, 0x80]))))
        await waitFor { replacement.text != nil }
        #expect(model.entries.map(\.id) == [b.id, replacement.id])
        #expect(replacement.text == "Field: replacement")
        #expect(replacement.bytes == Data([0, 0x80]))
        #expect(b.text == "Field: second")
    }

    @Test func failureDoesNotBlockNextInspectionOrRetainOldText() async {
        let model = makeModel()
        let a = entry(1), b = entry(2)
        model.add([(a, { $0(.failure(NSError(domain: "Synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Decode unavailable"]))) }),
                   (b, { $0(.success(inspection(2, value: "decoded"))) })])
        await waitFor { b.text != nil }
        #expect(a.errorMessage == "Decode unavailable" && a.text == nil && a.bytes == nil)
        #expect(b.text == "Field: decoded")
    }

    @Test func cachedDetailsResolveCustomColumnsAndSnapshotsRetainLocalEdits() async {
        let model = makeModel()
        let a = entry(1)
        model.add([(a, { $0(.success(inspection(1, value: "42"))) })])
        await waitFor { a.text != nil }
        let custom = PacketCustomColumn(identifier: "custom.field.test", fieldName: "test.field", title: "Field")
        #expect(a.customValue(custom) == "42")
        #expect(a.customValue(custom) == "42")
        let changedField = PacketCustomColumn(identifier: custom.identifier, fieldName: "test.other", title: "Other")
        #expect(a.customValue(changedField) == "")
        #expect(a.customValue(custom) == "42")
        model.setComment("first\nsecond", on: [a.id])
        model.apply(.setHighlightColor(.purple), to: [a.id])
        model.apply(.toggleStrikethrough, to: [a.id])
        #expect(a.row.comment == "first\nsecond" && a.row.commentText == "first second")
        #expect(a.row.textStyle == PacketTextStyle(highlightColor: .purple, isStrikethrough: true))
        #expect(a.text == "Field: 42")
    }

    @Test func displayModePersistsAndIndentationParticipatesInDiff() {
        let defaults = isolatedDefaults()
        let model = DiffPoolModel(defaults: defaults)
        #expect(model.displayMode == .sideBySide)
        #expect(model.contentKind == .packetDetails)
        model.setDisplayMode(.unified)
        model.setContentKind(.packetBytes)
        #expect(DiffPoolModel(defaults: defaults).displayMode == .unified)
        #expect(DiffPoolModel(defaults: defaults).contentKind == .packetBytes)
        model.setContentKind(.packetDetails)
        #expect(model.displayMode == .unified)
        #expect(model.displayMode.editorOptions["renderSideBySide"] as? Bool == false)
        #expect(model.displayMode.editorOptions["ignoreTrimWhitespace"] as? Bool == false)
    }

    @Test func byteSnapshotsOwnBorrowedStorageAndNeedNoFurtherInspection() async {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 1)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0xFF, count: 32)
        let borrowed = Data(bytesNoCopy: storage, count: 32, deallocator: .none)
        let model = makeModel()
        let a = entry(1)
        var inspections = 0
        model.add([(a, { completion in
            inspections += 1
            completion(.success(inspection(1, value: "owned", bytes: borrowed)))
        })])
        await waitFor { a.bytes != nil }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        model.setContentKind(.packetBytes)
        model.setContentKind(.packetDetails)
        #expect(a.bytes == Data(repeating: 0xFF, count: 32))
        #expect(inspections == 1)
    }

    @Test func tableLayoutUsesSharedDefinitionsAndIndependentSizing() {
        let custom = PacketCustomColumn(identifier: "custom.field.test", fieldName: "test.field", title: "Field")
        let main = PacketTableColumnLayout(columns: [.init(identifier: "source", isVisible: true, width: 240)], customColumns: [custom])
        let first = DiffTableLayout.resolve(main: main, saved: nil)
        #expect(first.columns.first?.identifier == "source" && first.columns.first?.width == 240)
        let saved = PacketTableColumnLayout(columns: [.init(identifier: "source", isVisible: false, width: 110)])
        let resolved = DiffTableLayout.resolve(main: main, saved: saved)
        #expect(resolved.columns.first?.width == 110 && resolved.columns.first?.isVisible == false)
        #expect(resolved.customColumns == [custom])
        #expect(resolved.columns.contains { $0.identifier == custom.identifier })
        let defaults = isolatedDefaults()
        PacketTableColumnLayoutStore(defaults: defaults).save(main)
        PacketTableColumnLayoutStore(defaults: defaults, key: "TCPViewer.diff.columnLayout.v1").save(resolved)
        #expect(PacketTableColumnLayoutStore(defaults: defaults).load() == main)
    }

    @Test func externalComparisonUsesLiteralArguments() {
        let left = URL(fileURLWithPath: "/tmp/left $(command);file.txt")
        let right = URL(fileURLWithPath: "/tmp/right 'file'.txt")
        #expect(DiffExternalComparison.arguments(left: left, right: right) == [left.path, right.path])
    }

    @Test func copiedStoryboardLoadsWithSharedPacketCellsAndPacketFooter() throws {
        let storyboard = NSStoryboard(name: "Diff", bundle: Bundle(for: DiffWindowController.self))
        let controller = try #require(storyboard.instantiateController(withIdentifier: "DiffWindowController") as? DiffWindowController)
        _ = controller.window
        let defaults = isolatedDefaults()
        controller.configure(model: DiffPoolModel(defaults: defaults), configuration: AppConfiguration(defaults: defaults), layout: nil)
        let split = try #require(controller.contentViewController as? DiffSplitViewController)
        let pool = try #require(split.splitViewItems[0].viewController as? DiffPoolViewController)
        #expect(pool.tableView.tableColumns.prefix(2).map(\.title) == ["Left", "Right"])
        #expect(pool.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("protocol"))?.dataCell is PacketProtocolCell)
        #expect(pool.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("client"))?.dataCell is PacketClientCell)
        #expect(pool.mainMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Left Side", "Right Side", "Add Comment…", "Highlight", "Delete All", "Delete"])
        let content = try #require(split.splitViewItems[1].viewController as? DiffContentViewController)
        #expect(content.contentKindBtn.itemTitles == ["Packet Details", "Packet Bytes"])
        #expect(content.diffModeBtn.menu?.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Side By Side", "Unified"])
        #expect(content.diffModeBtn.menu?.items.filter(\.isSeparatorItem).count == 1)
        content.closeEditor()
    }

    @Test func diffWindowRoutesBracketShortcutsAndValidatesSideMenus() throws {
        let controller = try #require(NSStoryboard(name: "Diff", bundle: Bundle(for: DiffWindowController.self))
            .instantiateController(withIdentifier: "DiffWindowController") as? DiffWindowController)
        _ = controller.window
        let model = makeModel()
        let a = entry(1), b = entry(2), c = entry(3)
        model.add([(a, loading), (b, loading), (c, loading)])
        controller.configure(model: model, configuration: AppConfiguration(defaults: isolatedDefaults()), layout: nil)
        let split = try #require(controller.contentViewController as? DiffSplitViewController)
        let pool = try #require(split.splitViewItems[0].viewController as? DiffPoolViewController)
        pool.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        let leftEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0, context: nil,
            characters: "[", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33))
        #expect(controller.handleShortcut(leftEvent))
        #expect(model.left === c && model.right === b)
        let menu = NSMenu(title: "Diff")
        let leftItem = NSMenuItem(title: "Left Side", action: #selector(DiffWindowController.selectDiffLeft(_:)), keyEquivalent: "[")
        let addItem = NSMenuItem(title: "Add", action: #selector(TCPViewerWindowController.addSelectedPacketsToDiff(_:)), keyEquivalent: "y")
        menu.addItem(leftItem)
        menu.addItem(addItem)
        let app = AppDelegate()
        app.updateDiffMenu(menu, window: controller.window)
        #expect(leftItem.target === controller && leftItem.isEnabled && leftItem.state == .on)
        #expect(!addItem.isEnabled)
        pool.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        #expect(!controller.validateMenuItem(leftItem))
        let f7 = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 98))
        #expect(!controller.handleShortcut(f7))
        model.setContentKind(.packetBytes)
        #expect(controller.handleShortcut(f7))
        app.updateDiffMenu(menu, window: nil)
        #expect(!leftItem.isEnabled && leftItem.state == .off)
        controller.window?.close()
    }

    private let loading: DiffPoolModel.Inspect = { _ in }
    private func makeModel() -> DiffPoolModel { DiffPoolModel(defaults: isolatedDefaults()) }
    private func isolatedDefaults() -> UserDefaults { UserDefaults(suiteName: "DiffTests.\(UUID())")! }
    private func entry(_ id: UInt64, capture: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, lineage: UInt64 = 1) -> DiffPacketEntry {
        DiffPacketEntry(id: DiffPacketID(capture: capture, lineage: lineage, packet: id), row: PacketTableRow(packet: PacketSummary(
            id: id, packetNumber: id, timestamp: Date(timeIntervalSince1970: 0), source: .offline, transportHint: .tcp,
            endpoints: PacketEndpoints(source: PacketEndpoint(address: "192.0.2.1", port: 1234), destination: PacketEndpoint(address: "192.0.2.2", port: 443)),
            originalLength: 64, capturedLength: 64, infoSummary: "Synthetic TCP", layers: [PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete), captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )))
    }
    private func inspection(_ id: UInt64, value: String, bytes: Data = Data()) -> PacketInspection {
        PacketInspection(packetID: id, packetNumber: id, rawBytes: bytes, detailNodes: [PacketDetailNode(id: "field", name: "Field", fieldName: "test.field", value: value)], decodeStatus: PacketDecodeStatus(kind: .complete))
    }
    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(predicate())
    }
}
