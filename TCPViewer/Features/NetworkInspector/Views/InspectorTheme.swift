import AppKit

enum InspectorTheme {
    enum Spacing {
        static let outerPadding: CGFloat = 20
        static let cardPadding: CGFloat = 14
        static let cardSpacing: CGFloat = 14
        static let rowSpacing: CGFloat = 10
        static let chipSpacing: CGFloat = 6
        static let heroSpacing: CGFloat = 12
    }

    enum Radius {
        static let card: CGFloat = 12
        static let chip: CGFloat = 7
    }

    enum Palette {
        static var cardBackground: NSColor { .quaternarySystemFill }
        static var cardBorder: NSColor { .separatorColor.withAlphaComponent(0.5) }
        static var rowDivider: NSColor { .separatorColor.withAlphaComponent(0.4) }
        static var panelBackground: NSColor { .underPageBackgroundColor }
        static var sectionTitle: NSColor { .labelColor }
        static var rowLabel: NSColor { .secondaryLabelColor }
        static var rowValue: NSColor { .labelColor }
        static var connector: NSColor { .tertiaryLabelColor }
    }

    static func heroTitleFont(_ configuration: AppConfiguration) -> NSFont {
        configuration.packetFont(sizeDelta: 3, weight: .semibold)
    }

    static func heroSubtitleFont(_ configuration: AppConfiguration) -> NSFont {
        configuration.packetFont(sizeDelta: 0, weight: .regular)
    }

    static func sectionTitleFont(_ configuration: AppConfiguration) -> NSFont {
        configuration.packetFont(sizeDelta: 1, weight: .semibold)
    }

    static func rowLabelFont(_ configuration: AppConfiguration) -> NSFont {
        configuration.packetFont(weight: .regular)
    }

    static func rowValueFont(_ configuration: AppConfiguration) -> NSFont {
        let size = configuration.packetFont(weight: .regular).pointSize
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    static func chipFont(_ configuration: AppConfiguration) -> NSFont {
        configuration.packetFont(sizeDelta: -1, weight: .semibold)
    }

    static func card(content: NSView, padding: CGFloat = Spacing.cardPadding) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.cornerRadius = Radius.card
        container.layer?.backgroundColor = Palette.cardBackground.cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Palette.cardBorder.cgColor

        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
        ])
        return container
    }

    static func chip(text: String, tint: NSColor, configuration: AppConfiguration) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = chipFont(configuration)
        label.textColor = tint.blended(withFraction: 0.25, of: .labelColor) ?? tint
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = ChipView()
        container.tintColor = tint
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.cornerRadius = Radius.chip
        container.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = tint.withAlphaComponent(0.22).cgColor

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])
        return container
    }

    static func protocolStack(layers: [String], configuration: AppConfiguration) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4

        for (index, layer) in layers.enumerated() {
            let tint = PacketProtocolPalette.tint(for: layer)
            row.addArrangedSubview(chip(text: layer, tint: tint, configuration: configuration))

            if index < layers.count - 1 {
                let connector = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil) ?? NSImage())
                connector.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                connector.contentTintColor = Palette.connector
                row.addArrangedSubview(connector)
            }
        }
        return row
    }

    static func sectionHeader(symbol: String, title: String, configuration: AppConfiguration) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = sectionTitleFont(configuration)
        label.textColor = Palette.sectionTitle
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 6
        return stack
    }

    static func rowDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.rowDivider.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    static func keyValueRow(label: String, value: String, configuration: AppConfiguration) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = rowLabelFont(configuration)
        labelView.textColor = Palette.rowLabel
        labelView.lineBreakMode = .byTruncatingTail
        labelView.maximumNumberOfLines = 1
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        labelView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let valueView = NSTextField(labelWithString: value.isEmpty ? "—" : value)
        valueView.font = rowValueFont(configuration)
        valueView.textColor = Palette.rowValue
        valueView.alignment = .right
        valueView.lineBreakMode = .byTruncatingMiddle
        valueView.maximumNumberOfLines = 2
        valueView.isSelectable = true
        valueView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labelView, valueView])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 12
        return row
    }
}

final class ChipView: NSView {
    var tintColor: NSColor = .controlAccentColor
}
