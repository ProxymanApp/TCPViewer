//
//  TLSDecryptionViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import AppKit

protocol TLSDecryptionViewControllerDelegate: AnyObject {
    func tlsDecryptionViewController(_ controller: TLSDecryptionViewController, didSetDecryptionEnabled isEnabled: Bool)
    func tlsDecryptionViewController(_ controller: TLSDecryptionViewController, didAddFilesAt urls: [URL])
    func tlsDecryptionViewController(_ controller: TLSDecryptionViewController, didRemoveFilesWithIDs ids: Set<String>)
    func tlsDecryptionViewController(_ controller: TLSDecryptionViewController, didSetFileWithID id: String, enabled isEnabled: Bool)
}

struct TLSDecryptionRowModel: Equatable {
    let id: String
    let url: URL
    let title: String
    let subtitle: String
    let detail: String
    let isChecked: Bool
    let hasProblem: Bool
}

final class TLSDecryptionViewModel {
    private(set) var isEnabled = true
    private(set) var rows: [TLSDecryptionRowModel] = []
    private(set) var footerText = ""

    // Turn the store snapshot into the exact strings each row and the footer show.
    func render(snapshot: TLSDecryptionSnapshot) {
        isEnabled = snapshot.isEnabled
        rows = snapshot.files.map(Self.row)
        footerText = snapshot.activityMessage
    }

    private static func row(for file: TLSKeyLogFile) -> TLSDecryptionRowModel {
        let folder = (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        var subtitle = folder
        var detail = ""
        var hasProblem = true
        switch file.status {
        case .reading:
            detail = "Reading…"
            hasProblem = false
        case .ready(let sessionCount, let keyCount, let skippedLineCount):
            // Legacy RSA logs carry keys that are not tied to a client random, so they have no session count.
            detail = sessionCount > 0 ? counted(sessionCount, "session") : counted(keyCount, "key")
            if skippedLineCount > 0 {
                subtitle += " · \(counted(skippedLineCount, "line")) skipped"
            }
            hasProblem = false
        case .noKeys:
            subtitle += " · No TLS keys in this file"
        case .missing:
            subtitle += " · File not found"
        case .unreadable:
            subtitle += " · File cannot be read"
        case .tooLarge:
            subtitle += " · File is too large for a key log"
        }
        return TLSDecryptionRowModel(
            id: file.id,
            url: file.url,
            title: file.url.lastPathComponent,
            subtitle: subtitle,
            detail: detail,
            isChecked: file.isEnabled,
            hasProblem: hasProblem
        )
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

final class TLSDecryptionViewController: NSViewController {
    private enum Metrics {
        static let contentInset: CGFloat = 20
        static let sectionSpacing: CGFloat = 14
        static let rowHeight: CGFloat = 46
        static let listCornerRadius: CGFloat = 8
    }

    weak var delegate: TLSDecryptionViewControllerDelegate?

    private let viewModel = TLSDecryptionViewModel()
    private let iconView = NSImageView()
    private let enabledSwitch = NSSwitch()
    private let tableView = TLSKeyLogTableView()
    private let placeholderView = TCPViewerUI.placeholder(
        title: "No Key Log Files",
        imageName: "key",
        message: "Drop a TLS key log file here or click +. Browsers, curl and Proxyman write one when SSLKEYLOGFILE is set."
    )
    private let fileButtons = NSSegmentedControl()
    private let footerLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
        color: .secondaryLabelColor
    )

    override func loadView() {
        let dropView = TLSKeyLogDropView()
        dropView.dropHandler = { [weak self] urls in
            guard let self else { return }
            self.delegate?.tlsDecryptionViewController(self, didAddFilesAt: urls)
        }
        view = dropView
        setupLayout()
    }

    // Show the store's current files and status; the controller keeps no state of its own.
    func render(snapshot: TLSDecryptionSnapshot) {
        loadViewIfNeeded()
        let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { viewModel.rows.indices.contains($0) ? viewModel.rows[$0].id : nil })
        viewModel.render(snapshot: snapshot)

        enabledSwitch.state = viewModel.isEnabled ? .on : .off
        iconView.image = TCPViewerUI.image(viewModel.isEnabled ? "lock.open.fill" : "lock.fill")
        iconView.contentTintColor = viewModel.isEnabled ? .controlAccentColor : .secondaryLabelColor
        footerLabel.stringValue = viewModel.footerText
        footerLabel.toolTip = viewModel.footerText
        placeholderView.isHidden = !viewModel.rows.isEmpty

        tableView.reloadData()
        let selection = IndexSet(viewModel.rows.indices.filter { selectedIDs.contains(viewModel.rows[$0].id) })
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
        updateRemoveButton()
    }

    private func setupLayout() {
        let titleLabel = TCPViewerUI.label("Decrypt TLS traffic", font: .systemFont(ofSize: 13, weight: .semibold))
        let subtitleLabel = TCPViewerUI.label(
            "Show HTTPS as readable HTTP using TLS key log files.",
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            color: .secondaryLabelColor
        )
        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleDecryption(_:))
        enabledSwitch.setContentHuggingPriority(.required, for: .horizontal)

        let headerStack = NSStackView(views: [iconView, titleStack, NSView(), enabledSwitch])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12

        fileButtons.segmentCount = 2
        fileButtons.trackingMode = .momentary
        fileButtons.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        fileButtons.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        fileButtons.setWidth(30, forSegment: 0)
        fileButtons.setWidth(30, forSegment: 1)
        fileButtons.setToolTip("Add key log files", forSegment: 0)
        fileButtons.setToolTip("Remove the selected files", forSegment: 1)
        fileButtons.target = self
        fileButtons.action = #selector(addOrRemoveFiles(_:))
        fileButtons.setContentHuggingPriority(.required, for: .horizontal)
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.alignment = .right
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let footerStack = NSStackView(views: [fileButtons, footerLabel])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 12

        let listView = makeListView()
        let stack = NSStackView(views: [headerStack, listView, footerStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.sectionSpacing
        let inset = Metrics.contentInset
        TCPViewerUI.pin(stack, to: view, insets: NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset))
        NSLayoutConstraint.activate([
            headerStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // Build the rounded file list with its empty-state placeholder on top.
    private func makeListView() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TLSKeyLogFile"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Metrics.rowHeight
        tableView.allowsMultipleSelection = true
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.deleteHandler = { [weak self] in self?.removeSelectedFiles() }
        tableView.menu = makeRowMenu()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // NSBox takes dynamic colors, so the border and fill follow light and dark appearance.
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = Metrics.listCornerRadius
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.contentView = scrollView
        TCPViewerUI.pin(placeholderView, to: box)
        return box
    }

    private func makeRowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show in Finder", action: #selector(showClickedFileInFinder(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Remove", action: #selector(removeClickedFiles(_:)), keyEquivalent: "").target = self
        return menu
    }

    // Rows targeted by a context-menu click: the clicked row, or the whole selection when it is part of it.
    private var clickedRowIDs: Set<String> {
        let clickedRow = tableView.clickedRow
        guard viewModel.rows.indices.contains(clickedRow) else {
            return selectedRowIDs
        }
        return tableView.selectedRowIndexes.contains(clickedRow) ? selectedRowIDs : [viewModel.rows[clickedRow].id]
    }

    private var selectedRowIDs: Set<String> {
        Set(tableView.selectedRowIndexes.compactMap { viewModel.rows.indices.contains($0) ? viewModel.rows[$0].id : nil })
    }

    private func updateRemoveButton() {
        fileButtons.setEnabled(!tableView.selectedRowIndexes.isEmpty, forSegment: 1)
    }

    private func removeSelectedFiles() {
        let ids = selectedRowIDs
        guard !ids.isEmpty else { return }
        delegate?.tlsDecryptionViewController(self, didRemoveFilesWithIDs: ids)
    }

    // Key logs have no fixed extension (.txt, .log, .keys or none), so any file can be chosen.
    private func presentOpenPanel() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose TLS key log files (SSLKEYLOGFILE format)."
        panel.prompt = "Add"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            self.delegate?.tlsDecryptionViewController(self, didAddFilesAt: panel.urls)
        }
    }

    @objc private func toggleDecryption(_ sender: NSSwitch) {
        delegate?.tlsDecryptionViewController(self, didSetDecryptionEnabled: sender.state == .on)
    }

    @objc private func addOrRemoveFiles(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            presentOpenPanel()
        } else {
            removeSelectedFiles()
        }
    }

    @objc private func showClickedFileInFinder(_ sender: Any?) {
        let urls = viewModel.rows.filter { clickedRowIDs.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func removeClickedFiles(_ sender: Any?) {
        let ids = clickedRowIDs
        guard !ids.isEmpty else { return }
        delegate?.tlsDecryptionViewController(self, didRemoveFilesWithIDs: ids)
    }
}

extension TLSDecryptionViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard viewModel.rows.indices.contains(row) else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("TLSKeyLogFileCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TLSKeyLogFileCellView
            ?? TLSKeyLogFileCellView(identifier: identifier)
        let rowModel = viewModel.rows[row]
        cell.render(rowModel, isDecryptionEnabled: viewModel.isEnabled)
        cell.toggleHandler = { [weak self] isEnabled in
            guard let self else { return }
            self.delegate?.tlsDecryptionViewController(self, didSetFileWithID: rowModel.id, enabled: isEnabled)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }
}

// Accepts any dropped file; the store decides whether it holds TLS keys.
private final class TLSKeyLogDropView: NSView {
    var dropHandler: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else {
            return false
        }
        dropHandler?(urls)
        return true
    }

    private func fileURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let urls = draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter { !$0.hasDirectoryPath }
    }
}

private final class TLSKeyLogTableView: NSTableView {
    var deleteHandler: (() -> Void)?

    // Let Delete and Forward Delete remove the selected files, as in Finder lists.
    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]
        guard deleteKeys.contains(event.keyCode), !selectedRowIndexes.isEmpty else {
            super.keyDown(with: event)
            return
        }
        deleteHandler?()
    }
}

private final class TLSKeyLogFileCellView: NSTableCellView {
    var toggleHandler: ((Bool) -> Void)?

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleLabel = TCPViewerUI.label("", font: .systemFont(ofSize: NSFont.systemFontSize))
    private let subtitleLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
        color: .secondaryLabelColor
    )
    private let detailLabel = TCPViewerUI.label(
        "",
        font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        color: .secondaryLabelColor
    )

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ row: TLSDecryptionRowModel, isDecryptionEnabled: Bool) {
        checkbox.state = row.isChecked ? .on : .off
        titleLabel.stringValue = row.title
        subtitleLabel.stringValue = row.subtitle
        subtitleLabel.textColor = row.hasProblem ? .systemOrange : .secondaryLabelColor
        subtitleLabel.toolTip = row.url.path
        detailLabel.stringValue = row.detail
        // Dim rows that contribute no keys, so the list reads as off without hiding what is configured.
        let isActive = isDecryptionEnabled && row.isChecked && !row.hasProblem
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
    }

    private func setupLayout() {
        checkbox.target = self
        checkbox.action = #selector(toggle(_:))
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [checkbox, textStack, NSView(), detailLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        TCPViewerUI.pin(stack, to: self, insets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 6))
    }

    @objc private func toggle(_ sender: NSButton) {
        toggleHandler?(sender.state == .on)
    }
}
