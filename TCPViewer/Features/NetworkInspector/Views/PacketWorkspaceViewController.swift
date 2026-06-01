//
//  PacketWorkspaceViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import AppKit
import PcapPlusPlusCore

protocol PacketWorkspaceViewControllerDelegate: AnyObject {
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didSelectPacket identifier: PacketSummary.ID?)
    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestPinPackets identifiers: [PacketSummary.ID]
    )
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestSavePackets identifiers: [PacketSummary.ID])
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestExportPackets identifiers: [PacketSummary.ID], format: CaptureFileFormat)
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestDeletePackets identifiers: [PacketSummary.ID])
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didUpdateStructuredFilterGroup group: PacketStructuredFilterGroup)
    func packetWorkspaceViewControllerDidRequestResetQuickFilters(_ controller: PacketWorkspaceViewController)
    func packetWorkspaceViewControllerCanAddStructuredFilter(_ controller: PacketWorkspaceViewController) -> Bool
    func packetWorkspaceViewControllerDidRequestStructuredFilterPaywall(_ controller: PacketWorkspaceViewController)
    func packetWorkspaceViewControllerDidRequestHideStructuredFilter(_ controller: PacketWorkspaceViewController)
}

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        drawingRect.origin.y += floor((drawingRect.height - textHeight) / 2)
        drawingRect.size.height = textHeight
        return drawingRect
    }
}

final class PacketWorkspaceViewModel {
    private(set) var title = "Packets"
    private(set) var countText = "0 visible"
    private(set) var totalText: String?
    private(set) var chips: [PacketFilterChip] = []
    private(set) var isEmpty = true
    private(set) var emptyTitle = "No Packets"
    private(set) var emptyMessage = "Start a live capture or open a pcap/pcapng file."
    private(set) var emptyImageName = "list.bullet.rectangle"
    private(set) var showsResetFiltersButton = false
    private(set) var quickFilterLabels: [String] = []

    // Convert the root snapshot into packet-workspace-only render data.
    func render(snapshot: NetworkInspectorSnapshot) {
        countText = "\(snapshot.visiblePacketCount) visible"
        totalText = snapshot.visiblePacketCount == snapshot.totalPacketCount ? nil : "of \(snapshot.totalPacketCount)"
        chips = snapshot.displayFilterChips
        isEmpty = snapshot.packetRows.isEmpty
        showsResetFiltersButton = isEmpty && snapshot.isQuickFilterActive
        quickFilterLabels = showsResetFiltersButton ? snapshot.quickFilterSelection.activeLabels : []

        if snapshot.isPacketTableFiltering && isEmpty {
            showsResetFiltersButton = false
            quickFilterLabels = []
        }

        if showsResetFiltersButton {
            emptyTitle = "No Matching Packets"
            emptyMessage = "Filtered by quick filters"
            emptyImageName = "line.3.horizontal.decrease.circle"
            return
        }

        switch snapshot.selectedSourceListSelection {
        case .pinned:
            emptyTitle = "Pinned Packets"
            emptyMessage = "Pinned matches will appear here as packets arrive."
            emptyImageName = "pin.fill"
        case .pinnedItem:
            emptyTitle = "Pinned Packets"
            emptyMessage = "No packets match this pinned item yet."
            emptyImageName = "pin.fill"
        case .saved:
            emptyTitle = "Saved Packets"
            emptyMessage = "Saved packets appear here after using the packet table menu."
            emptyImageName = "tray.and.arrow.down"
        default:
            emptyTitle = snapshot.totalPacketCount == 0 ? "No Packets" : "No Matching Packets"
            emptyMessage = snapshot.totalPacketCount == 0
                ? "Start a live capture or open a pcap/pcapng file."
                : "Adjust the packet filter to show packets again."
            emptyImageName = "list.bullet.rectangle"
        }
    }
}

final class PacketWorkspaceViewController: NSViewController {
    weak var delegate: PacketWorkspaceViewControllerDelegate?

    private let viewModel = PacketWorkspaceViewModel()
    private let contentContainer = NSView()
    private let structuredFilterController = PacketStructuredFilterViewController()
    private let tableController: PacketTableViewController
    private var placeholderView: NSView?
    private var isStructuredFilterVisible = false
    private var contentTopToFilterBottomConstraint: NSLayoutConstraint?
    private var contentTopToSafeAreaConstraint: NSLayoutConstraint?

    init(configuration: AppConfiguration) {
        self.tableController = PacketTableViewController(configuration: configuration)
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
        setupContent()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableController.delegate = self
        structuredFilterController.delegate = self
    }

    // Render the packet workspace and swap between the table and empty state as needed.
    func render(snapshot: NetworkInspectorSnapshot) {
        viewModel.render(snapshot: snapshot)
        structuredFilterController.render(group: snapshot.structuredFilterGroup, isFiltering: snapshot.isPacketTableFiltering)
        applyStructuredFilterVisibility(snapshot.isStructuredFilterVisible)

        if viewModel.isEmpty {
            showPlaceholder(
                title: viewModel.emptyTitle,
                message: viewModel.emptyMessage,
                imageName: viewModel.emptyImageName,
                showsResetFiltersButton: viewModel.showsResetFiltersButton,
                quickFilterLabels: viewModel.quickFilterLabels
            )
        } else {
            showTable()
            tableController.render(snapshot: snapshot)
        }
    }

    func focusStructuredFilter() {
        applyStructuredFilterVisibility(true)
        structuredFilterController.focusLastFilterTextField()
    }

    private func setupContent() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        addChild(structuredFilterController)
        addChild(tableController)
        structuredFilterController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(structuredFilterController.view)

        let contentTopToFilterBottomConstraint = contentContainer.topAnchor.constraint(equalTo: structuredFilterController.view.bottomAnchor)
        let contentTopToSafeAreaConstraint = contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        self.contentTopToFilterBottomConstraint = contentTopToFilterBottomConstraint
        self.contentTopToSafeAreaConstraint = contentTopToSafeAreaConstraint
        structuredFilterController.view.isHidden = true

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentTopToSafeAreaConstraint,
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            structuredFilterController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            structuredFilterController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            structuredFilterController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }

    private func applyStructuredFilterVisibility(_ isVisible: Bool) {
        guard isStructuredFilterVisible != isVisible else {
            return
        }

        isStructuredFilterVisible = isVisible
        structuredFilterController.view.isHidden = !isVisible
        if isVisible {
            contentTopToSafeAreaConstraint?.isActive = false
            contentTopToFilterBottomConstraint?.isActive = true
        } else {
            contentTopToFilterBottomConstraint?.isActive = false
            contentTopToSafeAreaConstraint?.isActive = true
        }
    }

    private func showPlaceholder(
        title: String,
        message: String,
        imageName: String,
        showsResetFiltersButton: Bool,
        quickFilterLabels: [String]
    ) {
        if tableController.view.superview != nil {
            tableController.view.removeFromSuperview()
        }

        placeholderView?.removeFromSuperview()
        let placeholder = makePlaceholder(
            title: title,
            imageName: imageName,
            message: message,
            showsResetFiltersButton: showsResetFiltersButton,
            quickFilterLabels: quickFilterLabels
        )
        TCPViewerUI.pin(placeholder, to: contentContainer)
        placeholderView = placeholder
    }

    private func makePlaceholder(
        title: String,
        imageName: String,
        message: String,
        showsResetFiltersButton: Bool,
        quickFilterLabels: [String]
    ) -> NSView {
        let imageView = NSImageView(image: TCPViewerUI.image(imageName) ?? NSImage())
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor

        let titleLabel = TCPViewerUI.label(title, font: .systemFont(ofSize: 19, weight: .semibold))
        titleLabel.alignment = .center

        let messageView: NSView
        let messageWidthConstraint: NSLayoutConstraint?
        if quickFilterLabels.isEmpty {
            let messageLabel = TCPViewerUI.label(message, font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor)
            messageLabel.alignment = .center
            messageLabel.maximumNumberOfLines = 3
            messageView = messageLabel
            messageWidthConstraint = messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        } else {
            messageView = makeQuickFilterMessage(labels: quickFilterLabels)
            messageWidthConstraint = nil
        }

        var arrangedViews: [NSView] = [imageView, titleLabel, messageView]
        if showsResetFiltersButton {
            let resetButton = NSButton(title: "Reset Filters", target: self, action: #selector(resetQuickFilters(_:)))
            resetButton.bezelStyle = .rounded
            resetButton.controlSize = .regular
            resetButton.image = TCPViewerUI.image("arrow.counterclockwise")
            resetButton.imagePosition = .imageLeading
            arrangedViews.append(resetButton)
        }

        let stack = NSStackView(views: arrangedViews)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: imageView)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        messageWidthConstraint?.isActive = true
        return container
    }

    private func makeQuickFilterMessage(labels: [String]) -> NSView {
        let prefixLabel = TCPViewerUI.label(
            "Filtered by",
            font: .systemFont(ofSize: NSFont.systemFontSize),
            color: .secondaryLabelColor
        )

        let visibleLabels = Array(labels.prefix(4))
        var views: [NSView] = [prefixLabel] + visibleLabels.map(makeQuickFilterChip(title:))
        if labels.count > visibleLabels.count {
            views.append(makeQuickFilterChip(title: "+\(labels.count - visibleLabels.count)"))
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func makeQuickFilterChip(title: String) -> NSView {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let label = TCPViewerUI.label(title, font: font)
        label.cell = VerticallyCenteredTextFieldCell(textCell: title)
        label.font = font
        label.textColor = .labelColor
        label.alignment = .center
        label.cell?.lineBreakMode = .byTruncatingTail

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 5
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.separatorColor.cgColor
        chip.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.65).cgColor

        TCPViewerUI.pin(label, to: chip, insets: NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9))
        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalToConstant: 24),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 130),
        ])
        return chip
    }

    private func showTable() {
        placeholderView?.removeFromSuperview()
        placeholderView = nil

        if tableController.view.superview == nil {
            TCPViewerUI.pin(tableController.view, to: contentContainer)
        }
    }

    @objc private func resetQuickFilters(_ sender: Any?) {
        delegate?.packetWorkspaceViewControllerDidRequestResetQuickFilters(self)
    }
}

#if DEBUG
extension PacketWorkspaceViewController {
    // Selects a random packet row through the table controller for debug crash reproduction.
    @discardableResult
    func selectRandomPacketRowForTesting() -> Bool {
        guard !viewModel.isEmpty else {
            return false
        }

        showTable()
        return tableController.selectRandomPacketRowForTesting()
    }
}
#endif

extension PacketWorkspaceViewController: PacketTableViewControllerDelegate {
    func packetTableViewController(_ controller: PacketTableViewController, didSelectPacket identifier: PacketSummary.ID?) {
        delegate?.packetWorkspaceViewController(self, didSelectPacket: identifier)
    }

    func packetTableViewController(
        _ controller: PacketTableViewController,
        didRequestPinPackets identifiers: [PacketSummary.ID]
    ) {
        delegate?.packetWorkspaceViewController(
            self,
            didRequestPinPackets: identifiers
        )
    }

    func packetTableViewController(_ controller: PacketTableViewController, didRequestSavePackets identifiers: [PacketSummary.ID]) {
        delegate?.packetWorkspaceViewController(self, didRequestSavePackets: identifiers)
    }

    func packetTableViewController(_ controller: PacketTableViewController, didRequestExportPackets identifiers: [PacketSummary.ID], format: CaptureFileFormat) {
        delegate?.packetWorkspaceViewController(self, didRequestExportPackets: identifiers, format: format)
    }

    func packetTableViewController(_ controller: PacketTableViewController, didRequestDeletePackets identifiers: [PacketSummary.ID]) {
        delegate?.packetWorkspaceViewController(self, didRequestDeletePackets: identifiers)
    }
}

extension PacketWorkspaceViewController: PacketStructuredFilterViewControllerDelegate {
    func packetStructuredFilterViewController(_ controller: PacketStructuredFilterViewController, didUpdate group: PacketStructuredFilterGroup) {
        delegate?.packetWorkspaceViewController(self, didUpdateStructuredFilterGroup: group)
    }

    func packetStructuredFilterViewControllerCanAddFilter(_ controller: PacketStructuredFilterViewController) -> Bool {
        delegate?.packetWorkspaceViewControllerCanAddStructuredFilter(self) ?? true
    }

    func packetStructuredFilterViewControllerDidRequestPaywall(_ controller: PacketStructuredFilterViewController) {
        delegate?.packetWorkspaceViewControllerDidRequestStructuredFilterPaywall(self)
    }

    func packetStructuredFilterViewControllerDidRequestHide(_ controller: PacketStructuredFilterViewController) {
        delegate?.packetWorkspaceViewControllerDidRequestHideStructuredFilter(self)
    }
}
