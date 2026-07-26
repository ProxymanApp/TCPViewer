//
//  PacketCommentSheetViewControllerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/7/26.
//

import AppKit
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct PacketCommentSheetViewControllerTests {
    @MainActor
    @Test func providesMultilineEditorAndProminentCommandReturnSave() throws {
        var savedComment: String?
        let controller = PacketCommentSheetViewController(initialComment: "Existing") {
            savedComment = $0
        }
        controller.loadViewIfNeeded()

        let textView = try #require(Self.descendants(of: controller.view).compactMap { $0 as? NSTextView }.first)
        let buttons = Self.descendants(of: controller.view).compactMap { $0 as? NSButton }
        let cancelButton = try #require(buttons.first { $0.title == "Cancel" })
        let saveButton = try #require(buttons.first { $0.title == "Save" })

        #expect(!textView.isRichText)
        #expect(cancelButton.keyEquivalent == "\u{1b}")
        #expect(saveButton.bezelColor == .controlAccentColor)
        #expect(saveButton.keyEquivalent == "\r")
        #expect(saveButton.keyEquivalentModifierMask == .command)

        textView.string = "  First line\nSecond line  \n"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        saveButton.performClick(nil)
        #expect(savedComment == "First line\nSecond line")
    }

    @MainActor
    @Test func rejectsInputBeyondOneThousandCharacters() throws {
        let controller = PacketCommentSheetViewController(initialComment: nil) { _ in }
        controller.loadViewIfNeeded()
        let textView = try #require(Self.descendants(of: controller.view).compactMap { $0 as? NSTextView }.first)

        #expect(controller.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: "First line\nSecond line"
        ))
        #expect(!controller.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: String(repeating: "x", count: 1_001)
        ))
    }

    @MainActor
    @Test func multiplePacketModeExplainsThatEverySelectionWillChange() {
        let controller = PacketCommentSheetViewController(initialComment: nil, packetCount: 3) { _ in }
        controller.loadViewIfNeeded()
        let labels = Self.descendants(of: controller.view)
            .compactMap { ($0 as? NSTextField)?.stringValue }

        #expect(labels.contains("Add Comment to 3 Packets"))
        #expect(labels.contains("This comment will be applied to 3 selected packets."))
    }

    @MainActor
    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }
}
