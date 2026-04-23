import AppKit
import SwiftUI

struct SplitViewAutosaveConfigurator: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> SplitViewProbe {
        SplitViewProbe(name: name)
    }

    func updateNSView(_ nsView: SplitViewProbe, context: Context) {
        nsView.name = name
        nsView.applyAutosaveNameIfNeeded()
    }
}

final class SplitViewProbe: NSView {
    var name: String

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyAutosaveNameIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAutosaveNameIfNeeded()
    }

    func applyAutosaveNameIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            var ancestor: NSView? = self.superview
            while let currentAncestor = ancestor {
                if let splitView = currentAncestor as? NSSplitView {
                    splitView.autosaveName = NSSplitView.AutosaveName(self.name)
                    return
                }
                ancestor = currentAncestor.superview
            }
        }
    }
}

extension View {
    @ViewBuilder
    func packetryToolbarButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}
