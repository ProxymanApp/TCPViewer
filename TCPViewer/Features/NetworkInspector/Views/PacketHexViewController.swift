//
//  PacketHexViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 29/4/26.
//

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

enum TCPFollowPayloadMatcher {
    // Prefer the smallest reassembled source, then fall back to a unique match in the frame.
    static func matchingRange(for payload: Data, in byteViews: [PacketByteView]) -> PacketByteRange? {
        guard !payload.isEmpty else {
            return nil
        }

        let candidates = byteViews.compactMap { byteView -> Candidate? in
            guard let offset = uniqueOffset(of: payload, in: byteView.bytes) else {
                return nil
            }
            return Candidate(
                byteView: byteView,
                offset: offset,
                isReassembled: isReassembled(byteView)
            )
        }.sorted(by: isPreferred)

        guard let candidate = candidates.first else {
            return nil
        }
        if candidates.count > 1, hasEqualPriority(candidate, candidates[1]) {
            return nil
        }
        return PacketByteRange(
            offset: candidate.offset,
            length: payload.count,
            sourceID: candidate.byteView.id
        )
    }

    private struct Candidate {
        let byteView: PacketByteView
        let offset: Int
        let isReassembled: Bool
    }

    private static func uniqueOffset(of payload: Data, in bytes: Data) -> Int? {
        guard let firstRange = bytes.range(of: payload) else {
            return nil
        }
        let nextIndex = bytes.index(after: firstRange.lowerBound)
        guard bytes[nextIndex...].range(of: payload) == nil else {
            return nil
        }
        return bytes.distance(from: bytes.startIndex, to: firstRange.lowerBound)
    }

    private static func isReassembled(_ byteView: PacketByteView) -> Bool {
        byteView.id.localizedCaseInsensitiveContains("reassembled") ||
            byteView.label.localizedCaseInsensitiveContains("reassembled")
    }

    private static func isPreferred(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.isReassembled != rhs.isReassembled {
            return lhs.isReassembled
        }
        if lhs.byteView.bytes.count != rhs.byteView.bytes.count {
            return lhs.byteView.bytes.count < rhs.byteView.bytes.count
        }
        return lhs.byteView.id < rhs.byteView.id
    }

    private static func hasEqualPriority(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        lhs.isReassembled == rhs.isReassembled && lhs.byteView.bytes.count == rhs.byteView.bytes.count
    }
}

final class PacketHexViewController: NSViewController {
    private let configuration: AppConfiguration
    private let stackView = NSStackView()
    private let byteViewSegmentedControl = NSSegmentedControl()
    private let revealStatusLabel = NSTextField(labelWithString: "")
    private let hexTextView = HFTextView()
    private var renderedPacketID: PacketSummary.ID?
    private var renderedByteViewID: String?
    private var renderedBytes: Data?
    private var renderedByteViews: [PacketByteView] = []
    private var renderedHighlight: PacketHexHighlight?
    private var manualByteViewID: String?
    private var manualRevealPacketID: PacketSummary.ID?
    private var manualRevealRange: PacketByteRange?
    private var manualRevealByteViewID: String?

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = TCPViewerDynamicBackgroundView(backgroundColor: .controlBackgroundColor)
        setupStackView()
        setupByteViewControl()
        setupRevealStatusLabel()
        setupHexTextView()
    }

    // Forward snapshot callers to the narrow inspection-state renderer.
    func render(snapshot: NetworkInspectorSnapshot) {
        render(inspectionState: snapshot.base.inspectionState)
    }

    // Render packet bytes and keep the HexFiend selection aligned with inspector tree selection.
    func render(inspectionState: PacketInspectionState) {
        let inspection = currentInspection(in: inspectionState)
        if manualRevealPacketID != inspectionState.selectedPacketID {
            clearManualReveal()
        }
        if shouldKeepRenderedBytes(whileLoading: inspectionState, currentInspection: inspection) {
            updateRenderedHighlight(nil)
            return
        }
        let byteViews = byteViews(for: inspection)
        if manualRevealPacketID != inspection?.packetID {
            clearManualReveal()
        }
        // A protocol-tree selection takes precedence over the Follow TCP reveal context.
        if inspectionState.highlightedByteRange != nil {
            manualByteViewID = nil
            clearManualReveal()
        }

        renderByteViewControl(byteViews: byteViews)
        let requestedRange = inspectionState.highlightedByteRange ?? manualRevealRange
        let selectedByteView = selectedByteView(in: byteViews, highlightedRange: requestedRange)
        let contentChanged = renderedPacketID != inspection?.packetID ||
            renderedByteViewID != selectedByteView?.id ||
            renderedBytes != selectedByteView?.bytes

        if contentChanged {
            renderedPacketID = inspection?.packetID
            renderedByteViewID = selectedByteView?.id
            renderedBytes = selectedByteView?.bytes
            renderedHighlight = nil
            hexTextView.data = selectedByteView?.bytes ?? Data()
            configureReadOnlyController()
            selectRenderedSegment()
        }

        let byteCount = selectedByteView?.bytes.count ?? 0
        let highlight = PacketHexHighlight.make(from: requestedRange, byteCount: byteCount)
        updateRenderedHighlight(highlight, force: contentChanged)
    }

    // Select the exact byte source and range represented by a Follow TCP transcript record.
    @discardableResult
    func revealTCPFollowPayload(_ target: TCPFollowRevealTarget) -> Bool {
        guard renderedPacketID == target.packetID else {
            return false
        }
        guard let range = TCPFollowPayloadMatcher.matchingRange(for: target.payload, in: renderedByteViews),
              let byteView = renderedByteViews.first(where: { $0.id == range.sourceID }),
              let highlight = PacketHexHighlight.make(from: range, byteCount: byteView.bytes.count) else {
            clearManualReveal()
            if let byteView = selectedByteView(in: renderedByteViews, highlightedRange: nil) {
                display(byteView: byteView, highlight: nil)
            } else {
                updateRenderedHighlight(nil, force: true)
            }
            manualRevealPacketID = target.packetID
            showRevealStatus("Reassembled from multiple packets")
            return false
        }

        manualRevealPacketID = target.packetID
        manualRevealRange = range
        manualRevealByteViewID = byteView.id
        display(byteView: byteView, highlight: highlight)
        showRevealStatus(nil)
        return true
    }

    private func setupStackView() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4

        view.addSubview(stackView)
        TCPViewerUI.pin(stackView, to: view)
    }

    private func setupByteViewControl() {
        byteViewSegmentedControl.segmentStyle = .texturedRounded
        byteViewSegmentedControl.target = self
        byteViewSegmentedControl.action = #selector(byteViewSelectionChanged)
        byteViewSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        byteViewSegmentedControl.isHidden = true

        stackView.addArrangedSubview(byteViewSegmentedControl)
        byteViewSegmentedControl.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func setupRevealStatusLabel() {
        revealStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        revealStatusLabel.textColor = .secondaryLabelColor
        revealStatusLabel.lineBreakMode = .byTruncatingTail
        revealStatusLabel.isHidden = true
        revealStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(revealStatusLabel)
        revealStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: stackView.trailingAnchor).isActive = true
    }

    private func setupHexTextView() {
        hexTextView.translatesAutoresizingMaskIntoConstraints = false
        hexTextView.bordered = false
        hexTextView.backgroundColors = [.controlBackgroundColor]
        hexTextView.data = Data()
        configureReadOnlyController()

        stackView.addArrangedSubview(hexTextView)
        hexTextView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    private func configureReadOnlyController() {
        let controller = hexTextView.controller
        controller.editable = false
        controller.font = configuration.packetFont(sizeDelta: -1)
        if controller.responds(to: #selector(setter: HFController.shouldColorBytes)) {
            controller.shouldColorBytes = false
        }
        _ = controller.setBytesPerColumn(1)
    }

    private func currentInspection(in state: PacketInspectionState) -> PacketInspection? {
        guard let inspection = state.inspection,
              state.selectedPacketID == inspection.packetID else {
            return nil
        }

        return inspection
    }

    private func byteViews(for inspection: PacketInspection?) -> [PacketByteView] {
        guard let inspection else {
            return []
        }

        return inspection.byteViews.isEmpty
            ? [PacketByteView(id: "frame", label: "Frame", bytes: inspection.rawBytes)]
            : inspection.byteViews
    }

    private func selectedByteView(in byteViews: [PacketByteView], highlightedRange: PacketByteRange?) -> PacketByteView? {
        guard !byteViews.isEmpty else {
            return nil
        }

        let requestedID = manualRevealByteViewID ?? manualByteViewID ?? highlightedRange?.sourceID ?? "frame"
        return byteViews.first { $0.id == requestedID } ?? byteViews.first { $0.id == "frame" } ?? byteViews[0]
    }

    private func renderByteViewControl(byteViews: [PacketByteView]) {
        let identifiers = byteViews.map(\.id)
        guard identifiers != renderedByteViews.map(\.id) else {
            renderedByteViews = byteViews
            selectRenderedSegment()
            return
        }

        renderedByteViews = byteViews
        byteViewSegmentedControl.segmentCount = byteViews.count
        for (index, byteView) in byteViews.enumerated() {
            byteViewSegmentedControl.setLabel(byteView.label, forSegment: index)
            byteViewSegmentedControl.setWidth(0, forSegment: index)
            byteViewSegmentedControl.setEnabled(true, forSegment: index)
        }
        byteViewSegmentedControl.isHidden = byteViews.count <= 1
        selectRenderedSegment()
    }

    private func selectRenderedSegment() {
        guard !renderedByteViews.isEmpty else {
            byteViewSegmentedControl.selectedSegment = -1
            return
        }
        guard let renderedByteViewID,
              let index = renderedByteViews.firstIndex(where: { $0.id == renderedByteViewID }) else {
            byteViewSegmentedControl.selectedSegment = renderedByteViews.firstIndex(where: { $0.id == "frame" }) ?? 0
            return
        }
        byteViewSegmentedControl.selectedSegment = index
    }

    @objc private func byteViewSelectionChanged() {
        let selectedIndex = byteViewSegmentedControl.selectedSegment
        guard renderedByteViews.indices.contains(selectedIndex) else {
            return
        }

        let byteView = renderedByteViews[selectedIndex]
        manualByteViewID = byteView.id
        clearManualReveal()
        display(byteView: byteView, highlight: nil)
    }

    private func display(byteView: PacketByteView, highlight: PacketHexHighlight?) {
        renderedByteViewID = byteView.id
        renderedBytes = byteView.bytes
        renderedHighlight = nil
        hexTextView.data = byteView.bytes
        configureReadOnlyController()
        selectRenderedSegment()
        updateRenderedHighlight(highlight, force: true)
    }

    private func clearManualReveal() {
        manualRevealPacketID = nil
        manualRevealRange = nil
        manualRevealByteViewID = nil
        showRevealStatus(nil)
    }

    private func showRevealStatus(_ message: String?) {
        revealStatusLabel.stringValue = message ?? ""
        revealStatusLabel.isHidden = message == nil
    }

    // Preserve the old bytes until the newly selected packet finishes decoding.
    private func shouldKeepRenderedBytes(whileLoading state: PacketInspectionState, currentInspection: PacketInspection?) -> Bool {
        state.isLoading && currentInspection == nil && renderedBytes != nil
    }

    // Apply a hex highlight only when it actually changed, unless packet bytes changed too.
    private func updateRenderedHighlight(_ highlight: PacketHexHighlight?, force: Bool = false) {
        guard force || highlight != renderedHighlight else {
            return
        }

        renderedHighlight = highlight
        applyHighlight(highlight)
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
