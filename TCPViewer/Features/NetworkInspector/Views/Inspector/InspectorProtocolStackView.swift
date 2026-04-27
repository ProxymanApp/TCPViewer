import AppKit
import PcapPlusPlusCore

protocol InspectorProtocolStackViewDelegate: AnyObject {
    func protocolStackView(_ view: InspectorProtocolStackView, didSelectLayerNodeID identifier: String)
}

final class InspectorProtocolStackView: NSView {
    weak var delegate: InspectorProtocolStackViewDelegate?

    private let scrollView = NSScrollView()
    private let row = NSStackView()
    private var configuration: AppConfiguration
    private var currentLayerIDs: [String] = []

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyConfiguration(_ configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func render(layerNodes: [PacketDetailNode], selectedLayerNodeID: String?) {
        // Only top-level nodes that are layers count for the protocol stack.
        let layers = layerNodes.filter { $0.kind == .layer }
        let layerIDs = layers.map(\.id)

        // Avoid full rebuild on every selection change.
        if layerIDs != currentLayerIDs {
            for view in row.arrangedSubviews {
                row.removeArrangedSubview(view)
                view.removeFromSuperview()
            }

            for (index, layer) in layers.enumerated() {
                let chip = makeChip(for: layer, isSelected: layer.id == selectedLayerNodeID)
                row.addArrangedSubview(chip)
                if index < layers.count - 1 {
                    row.addArrangedSubview(makeConnector())
                }
            }

            currentLayerIDs = layerIDs
            return
        }

        // Update selection state in place.
        var chipIndex = 0
        for view in row.arrangedSubviews {
            if let chip = view as? ProtocolChipButton {
                let layer = layers[chipIndex]
                chip.setSelected(layer.id == selectedLayerNodeID)
                chipIndex += 1
            }
        }
    }

    private func makeChip(for layer: PacketDetailNode, isSelected: Bool) -> ProtocolChipButton {
        let tint = PacketProtocolPalette.tint(for: layer.name)
        let chip = ProtocolChipButton(
            title: layer.name,
            tint: tint,
            font: InspectorTheme.chipFont(configuration)
        )
        chip.layerNodeID = layer.id
        chip.target = self
        chip.action = #selector(chipTapped(_:))
        chip.setSelected(isSelected)
        return chip
    }

    private func makeConnector() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        icon.contentTintColor = InspectorTheme.Palette.connector
        return icon
    }

    @objc private func chipTapped(_ sender: ProtocolChipButton) {
        guard let id = sender.layerNodeID else { return }
        delegate?.protocolStackView(self, didSelectLayerNodeID: id)
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = InspectorTheme.Palette.headerBackground.cgColor

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = row
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: InspectorTheme.Spacing.headerHorizontal),
            scrollView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -InspectorTheme.Spacing.headerHorizontal),

            row.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            row.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])

        let bottomBorder = NSView()
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = InspectorTheme.Palette.cardBorder.cgColor
        addSubview(bottomBorder)
        NSLayoutConstraint.activate([
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

final class ProtocolChipButton: NSButton {
    var layerNodeID: String?
    private let tint: NSColor

    init(title: String, tint: NSColor, font: NSFont) {
        self.tint = tint
        super.init(frame: .zero)
        self.title = title
        self.font = font
        self.bezelStyle = .smallSquare
        self.isBordered = false
        self.contentTintColor = tint.blended(withFraction: 0.25, of: .labelColor) ?? tint
        self.setButtonType(.momentaryChange)
        self.wantsLayer = true
        self.layer?.cornerRadius = InspectorTheme.Radius.chip
        self.layer?.cornerCurve = .continuous
        self.layer?.borderWidth = 1
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: tint.blended(withFraction: 0.25, of: .labelColor) ?? tint,
        ]
        self.attributedTitle = NSAttributedString(
            string: "  \(title)  ",
            attributes: attributes
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        if selected {
            layer?.backgroundColor = tint.withAlphaComponent(0.32).cgColor
            layer?.borderColor = tint.withAlphaComponent(0.55).cgColor
        } else {
            layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
            layer?.borderColor = tint.withAlphaComponent(0.22).cgColor
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
