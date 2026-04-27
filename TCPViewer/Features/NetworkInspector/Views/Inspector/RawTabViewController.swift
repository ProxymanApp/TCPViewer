import AppKit
import PcapPlusPlusCore

final class RawTabViewController: NSViewController {
    private var configuration: AppConfiguration
    private let hexView: PacketHexFiendView
    private let statusLabel = NSTextField(labelWithString: "")
    private let placeholderContainer = NSView()
    private var hasInspection = false

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        self.hexView = PacketHexFiendView(configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = InspectorTheme.Palette.panelBackground.cgColor

        hexView.translatesAutoresizingMaskIntoConstraints = false
        placeholderContainer.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = makeStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(hexView)
        container.addSubview(placeholderContainer)
        container.addSubview(statusBar)

        NSLayoutConstraint.activate([
            hexView.topAnchor.constraint(equalTo: container.topAnchor),
            hexView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hexView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hexView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            placeholderContainer.topAnchor.constraint(equalTo: hexView.topAnchor),
            placeholderContainer.leadingAnchor.constraint(equalTo: hexView.leadingAnchor),
            placeholderContainer.trailingAnchor.constraint(equalTo: hexView.trailingAnchor),
            placeholderContainer.bottomAnchor.constraint(equalTo: hexView.bottomAnchor),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    func applyConfiguration(_ configuration: AppConfiguration) {
        self.configuration = configuration
        hexView.applyConfiguration(configuration)
        statusLabel.font = InspectorTheme.subtitleFont(configuration)
    }

    func render(state: PacketInspectorRenderState) {
        guard let inspection = state.inspection else {
            hasInspection = false
            renderPlaceholder(message: state.statusMessage, isLoading: state.isLoading, hasPacket: state.selectedPacketID != nil)
            statusLabel.stringValue = ""
            hexView.isHidden = true
            return
        }

        hexView.isHidden = false
        hasInspection = true
        clearPlaceholder()
        hexView.render(data: inspection.rawBytes, highlightedByteRange: state.highlightedByteRange)
        statusLabel.stringValue = statusText(forBytes: inspection.rawBytes, range: state.highlightedByteRange)
    }

    private func statusText(forBytes bytes: Data, range: PacketByteRange?) -> String {
        let total = "\(bytes.count) bytes"
        guard let range, range.length > 0 else {
            return "Total: \(total)"
        }
        let safeStart = max(0, min(range.offset, bytes.count))
        let safeEnd = max(safeStart, min(range.offset + range.length, bytes.count))
        let length = safeEnd - safeStart
        return "Total: \(total)  ·  Selection: \(safeStart)–\(safeEnd - 1)  ·  \(length) B"
    }

    private func makeStatusBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = InspectorTheme.Palette.headerBackground.cgColor

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = InspectorTheme.subtitleFont(configuration)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.isSelectable = true
        bar.addSubview(statusLabel)

        let topBorder = NSView()
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = InspectorTheme.Palette.cardBorder.cgColor
        bar.addSubview(topBorder)

        NSLayoutConstraint.activate([
            topBorder.heightAnchor.constraint(equalToConstant: 1),
            topBorder.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            topBorder.topAnchor.constraint(equalTo: bar.topAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: InspectorTheme.Spacing.headerHorizontal),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -InspectorTheme.Spacing.headerHorizontal),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            bar.heightAnchor.constraint(equalToConstant: 26),
        ])

        return bar
    }

    private func clearPlaceholder() {
        for view in placeholderContainer.subviews {
            view.removeFromSuperview()
        }
        placeholderContainer.isHidden = true
    }

    private func renderPlaceholder(message: String, isLoading: Bool, hasPacket: Bool) {
        clearPlaceholder()
        placeholderContainer.isHidden = false
        let placeholder: NSView
        if isLoading {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.startAnimation(nil)
            let label = NSTextField(labelWithString: "Decoding packet…")
            label.textColor = .secondaryLabelColor
            placeholder = NSStackView(views: [progress, label], orientation: .vertical, spacing: 8)
            (placeholder as? NSStackView)?.alignment = .centerX
        } else if hasPacket {
            placeholder = TCPViewerUI.placeholder(title: "Raw Bytes Unavailable", imageName: "binary", message: message, placement: .top)
        } else {
            placeholder = TCPViewerUI.placeholder(title: "Select a Packet", imageName: "sidebar.trailing", message: message, placement: .top)
        }
        TCPViewerUI.pin(placeholder, to: placeholderContainer)
    }
}
