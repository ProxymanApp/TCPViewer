import AppKit
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct PacketTableColumnServiceTests {
    @Test func defaultDefinitionsMatchInitialVisiblePacketTableColumns() {
        let service = PacketTableColumnService()

        #expect(service.definitions.map(\.identifier) == [
            "number",
            "time",
            "source",
            "destination",
            "sourcePort",
            "destinationPort",
            "protocol",
            "client",
            "domain",
            "streamID",
            "direction",
            "deltaTime",
            "streamDeltaTime",
            "tcpFlags",
            "tcpPayloadBytes",
            "pid",
            "bundleIdentifier",
            "decodeStatus",
            "interface",
            "length",
            "summary",
            "tags",
        ])
        #expect(service.visibleColumnIdentifiers == PacketTableColumnRole.visibleColumnIdentifiers)
        #expect(service.menuEntries.filter { $0.isVisible }.map(\.identifier) == PacketTableColumnRole.visibleColumnIdentifiers)
        #expect(service.menuEntries.filter { !$0.isVisible }.map(\.identifier) == [
            "sourcePort",
            "destinationPort",
            "streamID",
            "direction",
            "deltaTime",
            "streamDeltaTime",
            "tcpFlags",
            "tcpPayloadBytes",
            "pid",
            "bundleIdentifier",
            "decodeStatus",
            "interface",
        ])
    }

    @Test func togglesHiddenDefaultAndCustomColumnsThenResetsToInitialState() {
        let service = PacketTableColumnService(definitions: [
            .builtIn(.number, title: "#", defaultWidth: 68, minimumWidth: 52),
            .builtIn(.time, title: "Time", defaultWidth: 112, minimumWidth: 96, isDefaultVisible: false),
            .custom(identifier: "custom.tcpFlags", title: "TCP Flags", defaultWidth: 96, minimumWidth: 72),
        ])

        #expect(service.visibleColumnIdentifiers == ["number"])
        #expect(!service.isColumnVisible(identifier: "time"))
        #expect(!service.isColumnVisible(identifier: "custom.tcpFlags"))

        #expect(service.toggleColumnVisibility(identifier: "time"))
        #expect(service.setColumnVisibility(identifier: "custom.tcpFlags", isVisible: true))
        #expect(service.visibleColumnIdentifiers == ["number", "time", "custom.tcpFlags"])

        service.resetToDefaults()

        #expect(service.visibleColumnIdentifiers == ["number"])
        #expect(!service.isColumnVisible(identifier: "time"))
        #expect(!service.isColumnVisible(identifier: "custom.tcpFlags"))
    }

    @Test func preventsHidingTheLastVisibleColumn() {
        let service = PacketTableColumnService(definitions: [
            .builtIn(.number, title: "#", defaultWidth: 68, minimumWidth: 52),
            .builtIn(.time, title: "Time", defaultWidth: 112, minimumWidth: 96, isDefaultVisible: false),
        ])

        #expect(!service.canToggleColumnVisibility(identifier: "number"))
        #expect(!service.setColumnVisibility(identifier: "number", isVisible: false))
        #expect(service.isColumnVisible(identifier: "number"))

        #expect(service.setColumnVisibility(identifier: "time", isVisible: true))
        #expect(service.setColumnVisibility(identifier: "number", isVisible: false))
        #expect(service.visibleColumnIdentifiers == ["time"])
    }

    @Test func appliesSavedVisibilityAndIgnoresInvalidAllHiddenLayouts() {
        let service = PacketTableColumnService(definitions: [
            .builtIn(.number, title: "#", defaultWidth: 68, minimumWidth: 52),
            .builtIn(.time, title: "Time", defaultWidth: 112, minimumWidth: 96),
            .builtIn(.source, title: "Source", defaultWidth: 180, minimumWidth: 100, isDefaultVisible: false),
        ])

        service.applyVisibility(from: PacketTableColumnLayout(columns: [
            .init(identifier: "number", isVisible: false, width: 68),
            .init(identifier: "time", isVisible: true, width: 112),
            .init(identifier: "source", isVisible: true, width: 180),
            .init(identifier: "stale", isVisible: true, width: 200),
        ]))

        #expect(service.visibleColumnIdentifiers == ["time", "source"])

        service.applyVisibility(from: PacketTableColumnLayout(columns: [
            .init(identifier: "number", isVisible: false, width: 68),
            .init(identifier: "time", isVisible: false, width: 112),
            .init(identifier: "source", isVisible: false, width: 180),
        ]))

        #expect(service.visibleColumnIdentifiers == ["time", "source"])
    }

    @Test func layoutStoreRoundTripsAndClearsColumnLayout() throws {
        let defaults = Self.makeUserDefaults()
        let store = PacketTableColumnLayoutStore(defaults: defaults)
        let layout = PacketTableColumnLayout(columns: [
            .init(identifier: "number", isVisible: true, width: 70),
            .init(identifier: "sourcePort", isVisible: false, width: 92),
        ])

        #expect(store.load() == nil)

        store.save(layout)
        #expect(store.load() == layout)

        store.clear()
        #expect(store.load() == nil)
    }

    @MainActor
    @Test func columnVisibilityMenuUsesSmallControlsAndResetAtBottom() throws {
        let service = PacketTableColumnService(definitions: [
            .builtIn(.number, title: "#", defaultWidth: 68, minimumWidth: 52),
            .builtIn(.time, title: "Time", defaultWidth: 112, minimumWidth: 96, isDefaultVisible: false),
        ])
        let controller = PacketTableColumnVisibilityMenuController(columnService: service)
        let actionHandler = ColumnMenuActionHandler()
        controller.actionHandler = actionHandler

        let menu = controller.makeMenu()
        controller.menuNeedsUpdate(menu)

        let visibleTitles = menu.items.compactMap { $0.isSeparatorItem ? nil : $0.title }
        let numberButton = try #require(menu.items[0].view as? NSButton)
        let timeButton = try #require(menu.items[1].view as? NSButton)
        let resetButton = try #require(menu.items.last?.view as? NSButton)

        #expect(visibleTitles == ["#", "Time", "Reset All Columns"])
        #expect(menu.items[2].isSeparatorItem)
        #expect(numberButton.controlSize == .small)
        #expect(timeButton.controlSize == .small)
        #expect(resetButton.controlSize == .small)
        #expect(numberButton.state == .on)
        #expect(timeButton.state == .off)
    }
}

private final class ColumnMenuActionHandler: NSObject, PacketTableColumnVisibilityMenuActionHandling {
    func togglePacketTableColumnVisibilityFromMenu(_ sender: Any?) {}
    func resetPacketTableColumnsFromMenu(_ sender: Any?) {}
}

private extension PacketTableColumnServiceTests {
    static func makeUserDefaults() -> UserDefaults {
        let suiteName = "PacketTableColumnServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
