//
//  DiffBinaryViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import AppKit
import HexFiend

final class DiffBinaryViewController: NSViewController, DiffBinaryModelDelegate, HFTextViewDelegate {
    let leftHexView = HFTextView()
    let rightHexView = HFTextView()
    let statusLabel = NSTextField(labelWithString: "")
    let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")
    private let changeLabel = NSTextField(labelWithString: "")
    private let searchField = NSTextField()
    private let searchLabel = NSTextField(labelWithString: "")
    private let searchBar = NSStackView()
    private let model = DiffBinaryModel()
    private let font: NSFont
    private var paneTop: NSLayoutConstraint!
    private var paneSearchTop: NSLayoutConstraint!
    private var renderedPair: DiffBinaryPair?
    private var leftBytes: Data?
    private var rightBytes: Data?
    private var currentChange = 0
    private var synchronizing = false
    private var searchSide: DiffSide = .left

    init(font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)) {
        self.font = font
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Native hex panes share a compact status/search toolbar and adapt their row width to the window.
    override func loadView() {
        view = TCPViewerDynamicBackgroundView(backgroundColor: .controlBackgroundColor)
        model.delegate = self
        configureHexView(leftHexView)
        configureHexView(rightHexView)
        previousButton.target = self
        previousButton.action = #selector(previousChange(_:))
        previousButton.bezelStyle = .rounded
        previousButton.toolTip = "Previous difference (⇧F7)"
        nextButton.target = self
        nextButton.action = #selector(nextChange(_:))
        nextButton.bezelStyle = .rounded
        nextButton.toolTip = "Next difference (F7)"
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        changeLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        changeLabel.textColor = .secondaryLabelColor
        changeLabel.lineBreakMode = .byTruncatingTail
        changeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        let toolbar = NSStackView(views: [statusLabel, spacer, previousButton, nextButton])
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 4, right: 10)
        searchField.placeholderString = "Find hex bytes, e.g. 48 65 6C 6C 6F"
        searchField.target = self
        searchField.action = #selector(findNext(_:))
        let findButton = NSButton(title: "Find Next", target: self, action: #selector(findNext(_:)))
        findButton.bezelStyle = .rounded
        let closeButton = NSButton(title: "Done", target: self, action: #selector(closeSearch(_:)))
        closeButton.bezelStyle = .rounded
        searchLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchLabel.textColor = .secondaryLabelColor
        [searchField, searchLabel, findButton, closeButton].forEach { searchBar.addArrangedSubview($0) }
        searchBar.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 6, right: 10)
        searchBar.isHidden = true
        let divider = NSBox()
        divider.boxType = .separator
        let panes = NSView()
        let left = pane(label: leftLabel, hex: leftHexView)
        let right = pane(label: rightLabel, hex: rightHexView)
        for child in [left, divider, right] {
            child.translatesAutoresizingMaskIntoConstraints = false
            panes.addSubview(child)
            child.topAnchor.constraint(equalTo: panes.topAnchor).isActive = true
            child.bottomAnchor.constraint(equalTo: panes.bottomAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: panes.leadingAnchor),
            left.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: panes.trailingAnchor),
            left.widthAnchor.constraint(equalTo: right.widthAnchor)
        ])
        let changeRow = NSStackView(views: [changeLabel])
        changeRow.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 2, right: 10)
        for child in [toolbar, changeRow, searchBar, panes] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        }
        paneTop = panes.topAnchor.constraint(equalTo: changeRow.bottomAnchor)
        paneSearchTop = panes.topAnchor.constraint(equalTo: searchBar.bottomAnchor)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),
            changeRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            changeRow.heightAnchor.constraint(equalToConstant: 22),
            searchBar.topAnchor.constraint(equalTo: changeRow.bottomAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 32),
            paneTop,
            panes.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureHexView(_ hex: HFTextView) {
        hex.translatesAutoresizingMaskIntoConstraints = false
        hex.bordered = false
        hex.backgroundColors = [.controlBackgroundColor]
        hex.controller.font = font
        hex.controller.editable = false
        hex.controller.shouldColorBytes = false
        _ = hex.controller.setBytesPerColumn(1)
        let offsets = HFLineCountingRepresenter()
        offsets.minimumDigitCount = 4
        offsets.lineNumberFormat = .hexadecimal
        hex.controller.addRepresenter(offsets)
        hex.layoutRepresenter.addRepresenter(offsets)
        hex.delegate = self
    }

    private func pane(label: NSTextField, hex: HFTextView) -> NSView {
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pane = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(label)
        pane.addSubview(hex)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: pane.topAnchor, constant: 6),
            hex.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            hex.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            hex.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            hex.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])
        return pane
    }

    // Reuse immutable pool snapshots; styling or table updates do not repeat byte comparison.
    func render(left: DiffPacketEntry?, right: DiffPacketEntry?) {
        _ = view
        leftLabel.stringValue = caption("Left", entry: left)
        rightLabel.stringValue = caption("Right", entry: right)
        let pair = left.flatMap { left in right.map { DiffBinaryPair(left: left.snapshotIdentity, right: $0.snapshotIdentity) } }
        guard renderedPair != pair || leftBytes != left?.bytes || rightBytes != right?.bytes else { return }
        renderedPair = pair
        leftBytes = left?.bytes
        rightBytes = right?.bytes
        currentChange = 0
        synchronizing = true
        setBytes(leftBytes ?? Data(), in: leftHexView)
        setBytes(rightBytes ?? Data(), in: rightHexView)
        synchronizing = false
        if let pair, let leftBytes, let rightBytes {
            model.render(left: leftBytes, right: rightBytes, pair: pair)
        } else {
            model.clear()
            renderStatus()
        }
    }

    private func caption(_ side: String, entry: DiffPacketEntry?) -> String {
        guard let entry, let bytes = entry.bytes else { return "\(side) · Choose a packet" }
        return "\(side) · Packet #\(entry.row.numberText) · Captured frame · \(bytes.count) bytes"
    }

    private func setBytes(_ bytes: Data, in hex: HFTextView) {
        hex.controller.byteArray = HFAttributedByteArray(byteArray: HFBTreeByteArray(byteSlice: HFFullMemoryByteSlice(data: bytes)))
        hex.controller.editable = false
        hex.controller.selectedContentsRanges = [HFRangeWrapper.withRange(HFRange(location: 0, length: 0))]
    }

    func diffBinaryModelDidChange(_ model: DiffBinaryModel) {
        synchronizing = true
        for (hex, side) in [(leftHexView, DiffSide.left), (rightHexView, DiffSide.right)] {
            let attributes = hex.controller.byteRangeAttributeArray()
            attributes.removeAttribute(kHFAttributeDiffInsertion)
            attributes.removeAttribute(kHFAttributeFocused)
            for change in model.comparison?.changes ?? [] {
                let range = side == .left ? change.left : change.right
                if !range.isEmpty {
                    attributes.addAttribute(kHFAttributeDiffInsertion, range: hfRange(range))
                    // HexFiend's focused style keeps changed bytes legible in both appearances.
                    attributes.addAttribute(kHFAttributeFocused, range: hfRange(range))
                }
            }
            hex.controller.representer(nil, changedProperties: .byteRangeAttributes)
        }
        synchronizing = false
        renderStatus()
        if model.comparison?.changes.isEmpty == false { revealCurrentChange() }
    }

    private func renderStatus() {
        let count = model.comparison?.changes.count ?? 0
        previousButton.isEnabled = count > 0
        nextButton.isEnabled = count > 0
        if model.isComparing { statusLabel.stringValue = "Comparing packet bytes…" }
        else if model.failed { statusLabel.stringValue = "Could not compare packet bytes" }
        else if leftBytes == nil || rightBytes == nil { statusLabel.stringValue = "Choose a packet for Left and Right" }
        else if count == 0 { statusLabel.stringValue = "Identical bytes" }
        else { statusLabel.stringValue = "Difference \(currentChange + 1) of \(count)" }
        changeLabel.stringValue = "Highlighted bytes differ. Offsets are hexadecimal; the right column shows ASCII."
    }

    @objc func previousChange(_ sender: Any?) { moveChange(by: -1) }
    @objc func nextChange(_ sender: Any?) { moveChange(by: 1) }

    private func moveChange(by delta: Int) {
        guard let changes = model.comparison?.changes, !changes.isEmpty else { return }
        currentChange = (currentChange + delta + changes.count) % changes.count
        renderStatus()
        revealCurrentChange()
    }

    // Empty ranges are insertion/deletion positions, not neighboring bytes that should be highlighted.
    private func revealCurrentChange() {
        guard let changes = model.comparison?.changes, changes.indices.contains(currentChange) else { return }
        let change = changes[currentChange]
        synchronizing = true
        for (hex, range) in [(leftHexView, change.left), (rightHexView, change.right)] {
            hex.controller.selectedContentsRanges = [HFRangeWrapper.withRange(hfRange(range))]
            hex.controller.centerContentsRange(hfRange(range))
        }
        synchronizing = false
        changeLabel.stringValue = change.description
    }

    func hexTextView(_ hex: HFTextView, didChangeProperties properties: HFControllerPropertyBits) {
        guard !synchronizing, properties.contains(.displayedLineRange), let comparison = model.comparison else { return }
        let other = hex === leftHexView ? rightHexView : leftHexView
        let sourceOffset = Int(hex.controller.displayedLineRange.location * Double(hex.controller.bytesPerLine()))
        let offset = comparison.correspondingOffset(sourceOffset, from: hex === leftHexView ? .left : .right)
        var range = other.controller.displayedLineRange
        let total = Double(other.controller.totalLineCount())
        range.length = min(range.length, total)
        range.location = min(Double(offset) / Double(max(1, other.controller.bytesPerLine())), max(0, total - range.length))
        synchronizing = true
        other.controller.displayedLineRange = range
        synchronizing = false
    }

    func showSearchBar() {
        _ = view
        if let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: rightHexView) { searchSide = .right }
        else { searchSide = .left }
        searchBar.isHidden = false
        paneTop.isActive = false
        paneSearchTop.isActive = true
        searchLabel.stringValue = searchSide == .left ? "Left" : "Right"
        view.window?.makeFirstResponder(searchField)
    }

    @objc private func findNext(_ sender: Any?) {
        guard let needle = DiffBinarySearch.bytes(from: searchField.stringValue) else {
            searchLabel.stringValue = "Enter pairs of hex digits"
            return
        }
        let hex = searchSide == .left ? leftHexView : rightHexView
        let bytes = (searchSide == .left ? leftBytes : rightBytes) ?? Data()
        let start = min(bytes.count, Int(hex.controller.maximumSelectionLocation()))
        guard let found = DiffBinarySearch.next(needle, in: bytes, after: start) else {
            searchLabel.stringValue = "No matches"
            return
        }
        hex.controller.selectedContentsRanges = [HFRangeWrapper.withRange(hfRange(found))]
        hex.controller.maximizeVisibility(ofContentsRange: hfRange(found))
        searchLabel.stringValue = "0x\(String(found.lowerBound, radix: 16).uppercased())"
    }

    @objc private func closeSearch(_ sender: Any?) {
        searchBar.isHidden = true
        paneSearchTop.isActive = false
        paneTop.isActive = true
        let hex = searchSide == .left ? leftHexView : rightHexView
        if let representer = hex.layoutRepresenter.representers.first(where: { $0 is HFHexTextRepresenter }) {
            view.window?.makeFirstResponder(representer.view())
        }
    }

    private func hfRange(_ range: Range<Int>) -> HFRange {
        HFRange(location: UInt64(range.lowerBound), length: UInt64(range.count))
    }

    func suspend() {
        model.clear()
        renderedPair = nil
        leftBytes = nil
        rightBytes = nil
        if isViewLoaded {
            synchronizing = true
            setBytes(Data(), in: leftHexView)
            setBytes(Data(), in: rightHexView)
            synchronizing = false
        }
    }
}

// Hex searching works on raw bytes, including NUL and non-UTF8 values, without reformatting them.
enum DiffBinarySearch {
    static func bytes(from text: String) -> Data? {
        let digits = text.filter { !$0.isWhitespace }
        guard !digits.isEmpty, digits.utf8.count % 2 == 0, digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        let characters = Array(digits)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }

    static func next(_ needle: Data, in bytes: Data, after offset: Int) -> Range<Int>? {
        guard !needle.isEmpty else { return nil }
        let start = min(max(0, offset), bytes.count)
        return bytes.range(of: needle, in: start..<bytes.count) ?? bytes.range(of: needle, in: 0..<bytes.count)
    }
}
