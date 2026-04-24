import AppKit
import HexFiend
import PcapPlusPlusCore
import SwiftUI

struct PacketHexFiendView: NSViewRepresentable {
    let data: Data
    let highlightedByteRange: PacketByteRange?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> HFTextView {
        let textView = HFTextView(frame: .zero)
        textView.autoresizingMask = [.width, .height]
        textView.bordered = false
        textView.controller.editable = false
        textView.controller.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        textView.backgroundColors = [NSColor.textBackgroundColor]
        updateTextView(textView, coordinator: context.coordinator)
        return textView
    }

    func updateNSView(_ nsView: HFTextView, context: Context) {
        updateTextView(nsView, coordinator: context.coordinator)
    }

    private func updateTextView(_ textView: HFTextView, coordinator: Coordinator) {
        if coordinator.data != data {
            textView.data = data
            coordinator.data = data
            coordinator.selectionRange = nil
        }

        let selectionRange = PacketHexFiendSelectionRange(
            byteRange: highlightedByteRange,
            dataLength: data.count
        )
        guard coordinator.selectionRange != selectionRange else {
            return
        }

        coordinator.selectionRange = selectionRange
        if let selectionRange {
            let range = HFRangeMake(UInt64(selectionRange.offset), UInt64(selectionRange.length))
            textView.controller.selectedContentsRanges = [HFRangeWrapper.withRange(range)]
            textView.controller.centerContentsRange(range)
        } else {
            let cursorRange = HFRangeMake(0, 0)
            textView.controller.selectedContentsRanges = [HFRangeWrapper.withRange(cursorRange)]
        }
    }

    final class Coordinator {
        var data = Data()
        var selectionRange: PacketHexFiendSelectionRange?
    }
}

struct PacketHexFiendSelectionRange: Equatable {
    let offset: Int
    let length: Int

    init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }

    init?(byteRange: PacketByteRange?, dataLength: Int) {
        guard let byteRange, dataLength > 0, byteRange.length > 0 else {
            return nil
        }

        let end = byteRange.offset.addingReportingOverflow(byteRange.length)
        guard !end.overflow else {
            return nil
        }

        let clampedStart = min(max(byteRange.offset, 0), dataLength)
        let clampedEnd = min(max(end.partialValue, 0), dataLength)
        guard clampedEnd > clampedStart else {
            return nil
        }

        self.offset = clampedStart
        self.length = clampedEnd - clampedStart
    }
}
