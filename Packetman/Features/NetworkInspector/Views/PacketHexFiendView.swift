import AppKit
import HexFiend
import PcapPlusPlusCore

final class PacketHexFiendView: NSView {
    private let textView = HFTextView(frame: .zero)
    private var currentData = Data()
    private var currentSelectionRange: PacketHexFiendSelectionRange?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTextView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Render packet bytes and keep the selected decoded field centered.
    func render(data: Data, highlightedByteRange: PacketByteRange?) {
        if currentData != data {
            textView.data = data
            currentData = data
            currentSelectionRange = nil
        }

        let selectionRange = PacketHexFiendSelectionRange(
            byteRange: highlightedByteRange,
            dataLength: data.count
        )
        guard currentSelectionRange != selectionRange else {
            return
        }

        currentSelectionRange = selectionRange
        if let selectionRange {
            let range = HFRangeMake(UInt64(selectionRange.offset), UInt64(selectionRange.length))
            textView.controller.selectedContentsRanges = [HFRangeWrapper.withRange(range)]
            textView.controller.centerContentsRange(range)
        } else {
            let cursorRange = HFRangeMake(0, 0)
            textView.controller.selectedContentsRanges = [HFRangeWrapper.withRange(cursorRange)]
        }
    }

    private func setupTextView() {
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.autoresizingMask = [.width, .height]
        textView.bordered = false
        textView.controller.editable = false
        textView.controller.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        textView.backgroundColors = [NSColor.textBackgroundColor]
        addSubview(textView)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
