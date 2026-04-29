import AppKit
import HexFiend
import PcapPlusPlusCore

struct PacketHexHighlight: Equatable {
    let sourceRange: PacketByteRange
    let byteOffset: Int
    let byteLength: Int

    var tooltip: String {
        let endOffset = byteOffset + byteLength - 1
        if sourceRange.hasBitRange {
            let endBit = sourceRange.bitOffset + max(sourceRange.bitLength - 1, 0)
            return "Bytes \(byteOffset)-\(endOffset), bits \(sourceRange.bitOffset)-\(endBit)"
        }

        if byteLength == 1 {
            return "Byte \(byteOffset)"
        }

        return "Bytes \(byteOffset)-\(endOffset)"
    }

    static func make(from range: PacketByteRange?, byteCount: Int) -> PacketHexHighlight? {
        guard let range,
              byteCount > 0,
              range.offset >= 0,
              range.length > 0,
              range.offset < byteCount else {
            return nil
        }

        let byteLength = min(range.length, byteCount - range.offset)
        return PacketHexHighlight(sourceRange: range, byteOffset: range.offset, byteLength: byteLength)
    }
}

final class PacketHexViewController: NSViewController {
    private let configuration: AppConfiguration
    private let hexTextView = HFTextView()
    private var renderedPacketID: PacketSummary.ID?
    private var renderedRawBytes: Data?
    private var renderedHighlight: PacketHexHighlight?

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupHexTextView()
    }

    // Render packet bytes and keep the HexFiend selection aligned with inspector tree selection.
    func render(snapshot: NetworkInspectorSnapshot) {
        let inspectionState = snapshot.base.inspectionState
        let inspection = currentInspection(in: inspectionState)
        let contentChanged = renderedPacketID != inspection?.packetID || renderedRawBytes != inspection?.rawBytes

        if contentChanged {
            renderedPacketID = inspection?.packetID
            renderedRawBytes = inspection?.rawBytes
            renderedHighlight = nil
            hexTextView.data = inspection?.rawBytes ?? Data()
            configureReadOnlyController()
        }

        let byteCount = inspection?.rawBytes.count ?? 0
        let highlight = PacketHexHighlight.make(from: inspectionState.highlightedByteRange, byteCount: byteCount)
        guard contentChanged || highlight != renderedHighlight else {
            return
        }

        renderedHighlight = highlight
        applyHighlight(highlight)
    }

    private func setupHexTextView() {
        hexTextView.translatesAutoresizingMaskIntoConstraints = false
        hexTextView.bordered = false
        hexTextView.backgroundColors = [.controlBackgroundColor]
        hexTextView.data = Data()
        configureReadOnlyController()

        view.addSubview(hexTextView)
        TCPViewerUI.pin(hexTextView, to: view)
    }

    private func configureReadOnlyController() {
        let controller = hexTextView.controller
        controller.editable = false
        controller.font = configuration.packetFont(sizeDelta: -1)
        controller.shouldColorBytes = false
        _ = controller.setBytesPerColumn(1)
    }

    private func currentInspection(in state: PacketInspectionState) -> PacketInspection? {
        guard let inspection = state.inspection,
              state.selectedPacketID == inspection.packetID else {
            return nil
        }

        return inspection
    }

    private func applyHighlight(_ highlight: PacketHexHighlight?) {
        guard let highlight else {
            clearHighlight()
            return
        }

        let range = HFRange(location: UInt64(highlight.byteOffset), length: UInt64(highlight.byteLength))
        hexTextView.controller.selectedContentsRanges = [HFRangeWrapper.withRange(range)]
        hexTextView.controller.maximizeVisibility(ofContentsRange: range)
        hexTextView.toolTip = highlight.tooltip
    }

    private func clearHighlight() {
        let range = HFRange(location: 0, length: 0)
        hexTextView.controller.selectedContentsRanges = [HFRangeWrapper.withRange(range)]
        hexTextView.toolTip = nil
    }
}
