import AppKit

enum InspectorTheme {
    enum Spacing {
        static let outerPadding: CGFloat = 14
        static let cardPadding: CGFloat = 12
        static let cardSpacing: CGFloat = 10
        static let rowSpacing: CGFloat = 6
        static let chipSpacing: CGFloat = 4
        static let headerVertical: CGFloat = 8
        static let headerHorizontal: CGFloat = 14
    }

    enum Radius {
        static let card: CGFloat = 10
        static let chip: CGFloat = 6
        static let badge: CGFloat = 4
    }

    enum Palette {
        static var panelBackground: NSColor { .underPageBackgroundColor }
        static var headerBackground: NSColor { .windowBackgroundColor }
        static var cardBackground: NSColor { .quaternarySystemFill }
        static var cardBorder: NSColor { .separatorColor.withAlphaComponent(0.5) }
        static var rowDivider: NSColor { .separatorColor.withAlphaComponent(0.4) }
        static var sectionTitle: NSColor { .labelColor }
        static var rowLabel: NSColor { .secondaryLabelColor }
        static var rowValue: NSColor { .labelColor }
        static var connector: NSColor { .tertiaryLabelColor }
    }

    static func titleFont(_ configuration: AppConfiguration) -> NSFont {
        configuration.packetFont(sizeDelta: 1, weight: .semibold)
    }

    static func subtitleFont(_ configuration: AppConfiguration) -> NSFont {
        let size = configuration.packetFont(weight: .regular).pointSize
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    static func sectionTitleFont(_ configuration: AppConfiguration) -> NSFont {
        configuration.packetFont(sizeDelta: 0, weight: .semibold)
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

    static func badgeFont(_ configuration: AppConfiguration) -> NSFont {
        let size = max(9, configuration.packetFont(weight: .regular).pointSize - 2)
        return .systemFont(ofSize: size, weight: .heavy)
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

    static func sectionTitleLabel(_ title: String, configuration: AppConfiguration) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        let size = max(10, configuration.packetFont(weight: .regular).pointSize - 2)
        label.font = .systemFont(ofSize: size, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    static func keyValueRow(
        label: String,
        value: String,
        valueColor: NSColor = Palette.rowValue,
        configuration: AppConfiguration,
        valueIsSelectable: Bool = true
    ) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = rowLabelFont(configuration)
        labelView.textColor = Palette.rowLabel
        labelView.lineBreakMode = .byTruncatingTail
        labelView.maximumNumberOfLines = 1
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let valueView = NSTextField(labelWithString: value.isEmpty ? "—" : value)
        valueView.font = rowValueFont(configuration)
        valueView.textColor = valueColor
        valueView.alignment = .right
        valueView.lineBreakMode = .byTruncatingMiddle
        valueView.maximumNumberOfLines = 2
        valueView.isSelectable = valueIsSelectable
        valueView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labelView, valueView])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 12
        return row
    }

    static func rowDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.rowDivider.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    static func chip(text: String, tint: NSColor, configuration: AppConfiguration) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = chipFont(configuration)
        label.textColor = tint.blended(withFraction: 0.25, of: .labelColor) ?? tint
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.cornerRadius = Radius.chip
        container.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = tint.withAlphaComponent(0.22).cgColor

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
    }
}
