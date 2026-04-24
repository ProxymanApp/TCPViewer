import AppKit

enum PacketmanUI {
    enum PlaceholderPlacement {
        case center
        case top
    }

    static func image(_ systemName: String) -> NSImage? {
        NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
    }

    static func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    static func placeholder(
        title: String,
        imageName: String,
        message: String,
        placement: PlaceholderPlacement = .center
    ) -> NSView {
        let imageView = NSImageView(image: image(imageName) ?? NSImage())
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor

        let titleLabel = label(title, font: .systemFont(ofSize: 19, weight: .semibold))
        titleLabel.alignment = .center

        let messageLabel = label(message, font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3

        let stack = NSStackView(views: [imageView, titleLabel, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        var constraints = [
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ]
        switch placement {
        case .center:
            constraints.append(stack.centerYAnchor.constraint(equalTo: container.centerYAnchor))
        case .top:
            constraints.append(stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 36))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    static func pin(_ view: NSView, to container: NSView, insets: NSEdgeInsets = .zero) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

extension NSEdgeInsets {
    static let zero = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
}

extension NSStackView {
    convenience init(views: [NSView], orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat) {
        self.init(views: views)
        self.orientation = orientation
        self.spacing = spacing
    }
}
