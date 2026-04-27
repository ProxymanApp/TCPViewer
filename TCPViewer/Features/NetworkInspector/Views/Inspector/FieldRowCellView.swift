import AppKit
import PcapPlusPlusCore

protocol FieldRowCellViewDelegate: AnyObject {
    func fieldRow(_ cell: FieldRowCellView, didTapInfoForNodeID nodeID: String)
}

final class FieldRowCellView: NSTableCellView {
    static let nameReuseIdentifier = NSUserInterfaceItemIdentifier("FieldRowName")
    static let valueReuseIdentifier = NSUserInterfaceItemIdentifier("FieldRowValue")

    weak var delegate: FieldRowCellViewDelegate?

    private let label = NSTextField(labelWithString: "")
    private let badgeContainer = NSStackView()
    private let infoButton = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Info") ?? NSImage(), target: nil, action: nil)
    private var nodeID: String?
    private var isValueColumn = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        item: FieldsOutlineItem,
        isValueColumn: Bool,
        searchHighlight: String?,
        configuration: AppConfiguration,
        showInfoButton: Bool
    ) {
        self.nodeID = item.node.id
        self.isValueColumn = isValueColumn
        let node = item.node

        if isValueColumn {
            label.font = InspectorTheme.rowValueFont(configuration)
            label.alignment = .left
            label.lineBreakMode = .byTruncatingMiddle
            let raw = node.value ?? ""
            label.attributedStringValue = highlight(text: raw, query: searchHighlight, baseColor: textColor(for: node, isValue: true))
            renderBadges(for: node, configuration: configuration)
            infoButton.isHidden = true
        } else {
            label.font = InspectorTheme.rowLabelFont(configuration)
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
            let weight: NSFont.Weight = node.kind == .layer ? .semibold : .regular
            label.font = configuration.packetFont(weight: weight)
            label.attributedStringValue = highlight(text: node.name, query: searchHighlight, baseColor: textColor(for: node, isValue: false))
            removeBadges()
            infoButton.isHidden = !showInfoButton
        }
    }

    private func textColor(for node: PacketDetailNode, isValue: Bool) -> NSColor {
        if node.kind == .warning {
            return .systemOrange
        }
        return isValue ? .secondaryLabelColor : .labelColor
    }

    private func highlight(text: String, query: String?, baseColor: NSColor) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.foregroundColor: baseColor]
        )
        guard let query, !query.isEmpty, !text.isEmpty else {
            return attributed
        }

        let nsText = text as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)
        while searchRange.location < nsText.length {
            let found = nsText.range(of: query, options: .caseInsensitive, range: searchRange)
            if found.location == NSNotFound { break }
            attributed.addAttributes(
                [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45)],
                range: found
            )
            searchRange.location = found.location + max(found.length, 1)
            searchRange.length = nsText.length - searchRange.location
        }
        return attributed
    }

    private func renderBadges(for node: PacketDetailNode, configuration: AppConfiguration) {
        removeBadges()
        for badge in InspectorBadgeClassifier.badges(forField: node) {
            let view = InspectorBadgeView(text: badge.text, style: badge.style, configuration: configuration)
            badgeContainer.addArrangedSubview(view)
        }
    }

    private func removeBadges() {
        for view in badgeContainer.arrangedSubviews {
            badgeContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(label)

        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.orientation = .horizontal
        badgeContainer.spacing = 3
        badgeContainer.alignment = .centerY
        addSubview(badgeContainer)

        infoButton.translatesAutoresizingMaskIntoConstraints = false
        infoButton.bezelStyle = .inline
        infoButton.isBordered = false
        infoButton.imageScaling = .scaleProportionallyDown
        infoButton.contentTintColor = .tertiaryLabelColor
        infoButton.target = self
        infoButton.action = #selector(infoTapped(_:))
        infoButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        infoButton.isHidden = true
        addSubview(infoButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: infoButton.leadingAnchor, constant: -4),

            infoButton.trailingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: -4),
            infoButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoButton.widthAnchor.constraint(equalToConstant: 14),
            infoButton.heightAnchor.constraint(equalToConstant: 14),

            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badgeContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func infoTapped(_ sender: NSButton) {
        guard let nodeID else { return }
        delegate?.fieldRow(self, didTapInfoForNodeID: nodeID)
    }

    func infoButtonAnchorView() -> NSView {
        infoButton
    }
}
