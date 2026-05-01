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

final class PacketHexViewController: NSViewController {
    private let configuration: AppConfiguration
    private let stackView = NSStackView()
    private let byteViewSegmentedControl = NSSegmentedControl()
    private let hexTextView = HFTextView()
    private var renderedPacketID: PacketSummary.ID?
    private var renderedByteViewID: String?
    private var renderedBytes: Data?
    private var renderedByteViews: [PacketByteView] = []
    private var renderedHighlight: PacketHexHighlight?
    private var manualByteViewID: String?

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
        setupStackView()
        setupByteViewControl()
        setupHexTextView()
    }

    // Render packet bytes and keep the HexFiend selection aligned with inspector tree selection.
    func render(snapshot: NetworkInspectorSnapshot) {
        let inspectionState = snapshot.base.inspectionState
        let inspection = currentInspection(in: inspectionState)
        if shouldKeepRenderedBytes(whileLoading: inspectionState, currentInspection: inspection) {
            updateRenderedHighlight(nil)
            return
        }
        let byteViews = byteViews(for: inspection)
        if renderedPacketID != inspection?.packetID {
            manualByteViewID = nil
        } else if renderedHighlight?.sourceRange.sourceID != inspectionState.highlightedByteRange?.sourceID {
            manualByteViewID = nil
        }

        renderByteViewControl(byteViews: byteViews)
        let selectedByteView = selectedByteView(in: byteViews, highlightedRange: inspectionState.highlightedByteRange)
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
        let highlight = PacketHexHighlight.make(from: inspectionState.highlightedByteRange, byteCount: byteCount)
        updateRenderedHighlight(highlight, force: contentChanged)
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

        let requestedID = manualByteViewID ?? highlightedRange?.sourceID ?? "frame"
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
        renderedByteViewID = byteView.id
        renderedBytes = byteView.bytes
        renderedHighlight = nil
        hexTextView.data = byteView.bytes
        configureReadOnlyController()
        updateRenderedHighlight(nil, force: true)
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
