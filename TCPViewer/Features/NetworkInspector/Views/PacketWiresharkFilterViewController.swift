//
//  PacketWiresharkFilterViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import AppKit
import PcapPlusPlusCore

protocol PacketWiresharkFilterViewControllerDelegate: AnyObject {
    func packetWiresharkFilterViewController(
        _ controller: PacketWiresharkFilterViewController,
        didUpdateExpression expression: String
    )
    func packetWiresharkFilterViewControllerDidRequestApply(_ controller: PacketWiresharkFilterViewController)
    func packetWiresharkFilterViewController(
        _ controller: PacketWiresharkFilterViewController,
        didRequestApplyBeforeSaving completion: @escaping (Bool) -> Void
    )
    func packetWiresharkFilterViewController(
        _ controller: PacketWiresharkFilterViewController,
        didRequestSaveNamed name: String
    )
    func packetWiresharkFilterViewController(
        _ controller: PacketWiresharkFilterViewController,
        didRequestOverrideCustomFilter filterID: PacketCustomFilter.ID
    )
    func packetWiresharkFilterViewControllerCanSave(_ controller: PacketWiresharkFilterViewController) -> Bool
    func packetWiresharkFilterViewControllerDidRequestPaywall(_ controller: PacketWiresharkFilterViewController)
    func packetWiresharkFilterViewControllerDidRequestHide(_ controller: PacketWiresharkFilterViewController)
}

enum PacketWiresharkFilterTextRange {
    static func nsRange(for range: DisplayFilterSourceRange, in expression: String) -> NSRange? {
        let utf8 = expression.utf8
        guard range.utf8StartOffset <= utf8.count,
              range.utf8StartOffset + range.utf8Length <= utf8.count else {
            return nil
        }
        let utf8Start = utf8.index(utf8.startIndex, offsetBy: range.utf8StartOffset)
        let utf8End = utf8.index(utf8Start, offsetBy: range.utf8Length)
        guard let start = String.Index(utf8Start, within: expression),
              let end = String.Index(utf8End, within: expression) else {
            return nil
        }
        return NSRange(start..<end, in: expression)
    }

    static func column(for range: DisplayFilterSourceRange, in expression: String) -> Int {
        let utf8 = expression.utf8
        let offset = min(range.utf8StartOffset, utf8.count)
        let utf8Index = utf8.index(utf8.startIndex, offsetBy: offset)
        guard let stringIndex = String.Index(utf8Index, within: expression) else {
            return offset + 1
        }
        return expression.distance(from: expression.startIndex, to: stringIndex) + 1
    }
}

final class PacketWiresharkFilterViewController: NSViewController, NSTextFieldDelegate {
    weak var delegate: PacketWiresharkFilterViewControllerDelegate?

    private let expressionField = NSTextField()
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let helpButton = NSButton(title: "Syntax Help", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()
    private let diagnosticLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
        color: .secondaryLabelColor
    )
    private var renderedState = PacketWiresharkFilterState()
    private var customFilterItems: [PacketCustomFilterItem] = []

    override func loadView() {
        view = TCPViewerDynamicBackgroundView(backgroundColor: .windowBackgroundColor)
        setupLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        expressionField.delegate = self
        applyButton.target = self
        applyButton.action = #selector(applyFilter(_:))
        saveButton.target = self
        saveButton.action = #selector(saveFilter(_:))
        helpButton.target = self
        helpButton.action = #selector(openSyntaxHelp(_:))
        closeButton.target = self
        closeButton.action = #selector(hideFilter(_:))
    }

    func render(state: PacketWiresharkFilterState, customFilterItems: [PacketCustomFilterItem]) {
        renderedState = state
        self.customFilterItems = customFilterItems.filter { $0.mode == .wireshark }
        if expressionField.stringValue != state.draftExpression {
            expressionField.stringValue = state.draftExpression
        }
        applyButton.isEnabled = !state.isValidating && !state.isApplying
        saveButton.isEnabled = !state.isValidating && !state.isApplying
        progressIndicator.isHidden = !state.isValidating && !state.isApplying
        if state.isValidating || state.isApplying {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        renderDiagnostic(state)
    }

    func focusExpressionField() {
        view.window?.makeFirstResponder(expressionField)
        expressionField.currentEditor()?.moveToEndOfDocument(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        delegate?.packetWiresharkFilterViewController(self, didUpdateExpression: expressionField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            applyFilter(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hideFilter(nil)
            return true
        default:
            return false
        }
    }

    private func setupLayout() {
        expressionField.placeholderString = "Wireshark display filter, for example: ip.addr == 192.168.1.1"
        expressionField.usesSingleLineMode = true
        expressionField.lineBreakMode = .byClipping
        expressionField.cell?.isScrollable = true
        expressionField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        for button in [applyButton, saveButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        helpButton.bezelStyle = .inline
        helpButton.controlSize = .small
        helpButton.toolTip = "Open the Wireshark display-filter reference"

        closeButton.bezelStyle = .inline
        closeButton.controlSize = .small
        closeButton.image = TCPViewerUI.image("xmark")
        closeButton.toolTip = "Hide filter (Escape)"

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.isHidden = true

        diagnosticLabel.lineBreakMode = .byTruncatingTail
        diagnosticLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fieldRow = NSStackView(views: [expressionField, progressIndicator, applyButton, saveButton, helpButton, closeButton])
        fieldRow.orientation = .horizontal
        fieldRow.alignment = .centerY
        fieldRow.spacing = 8

        let stack = NSStackView(views: [fieldRow, diagnosticLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            expressionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            progressIndicator.widthAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -7),
            fieldRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        expressionField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func renderDiagnostic(_ state: PacketWiresharkFilterState) {
        if let progressText = state.progressText {
            diagnosticLabel.stringValue = progressText
            diagnosticLabel.textColor = .secondaryLabelColor
            return
        }
        guard let diagnostic = state.diagnostic else {
            diagnosticLabel.stringValue = state.appliedExpression.isEmpty ? "Use Wireshark display-filter syntax." : "Filter applied."
            diagnosticLabel.textColor = .secondaryLabelColor
            return
        }

        let columnText = diagnostic.range.map {
            "Column \(PacketWiresharkFilterTextRange.column(for: $0, in: state.draftExpression)): "
        } ?? ""
        diagnosticLabel.stringValue = columnText + diagnostic.message
        diagnosticLabel.textColor = diagnostic.severity == .warning ? .systemOrange : .systemRed
        if let range = diagnostic.range,
           let selection = PacketWiresharkFilterTextRange.nsRange(for: range, in: state.draftExpression),
           let editor = expressionField.currentEditor() {
            editor.selectedRange = selection
            editor.scrollRangeToVisible(selection)
        }
    }

    @objc private func applyFilter(_ sender: Any?) {
        delegate?.packetWiresharkFilterViewControllerDidRequestApply(self)
    }

    @objc private func saveFilter(_ sender: Any?) {
        guard delegate?.packetWiresharkFilterViewControllerCanSave(self) ?? true else {
            delegate?.packetWiresharkFilterViewControllerDidRequestPaywall(self)
            return
        }
        delegate?.packetWiresharkFilterViewController(self, didRequestApplyBeforeSaving: { [weak self] succeeded in
            guard succeeded else {
                return
            }
            self?.showSaveCustomFilterMenu()
        })
    }

    private func showSaveCustomFilterMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let newFilterItem = NSMenuItem(
            title: "New Filter...",
            action: #selector(saveNewCustomFilter(_:)),
            keyEquivalent: ""
        )
        newFilterItem.target = self
        menu.addItem(newFilterItem)
        menu.addItem(.separator())

        let overrideItem = NSMenuItem(title: "Override", action: nil, keyEquivalent: "")
        let overrideMenu = NSMenu()
        if customFilterItems.isEmpty {
            let emptyItem = NSMenuItem(title: "No Wireshark filters", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            overrideMenu.addItem(emptyItem)
        } else {
            for customItem in customFilterItems {
                let menuItem = NSMenuItem(
                    title: customItem.title,
                    action: #selector(overrideCustomFilter(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = customItem.id
                overrideMenu.addItem(menuItem)
            }
        }
        menu.addItem(overrideItem)
        menu.setSubmenu(overrideMenu, for: overrideItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: saveButton.bounds.height + 4), in: saveButton)
    }

    @objc private func saveNewCustomFilter(_ sender: Any?) {
        presentSaveNameAlert()
    }

    @objc private func overrideCustomFilter(_ sender: NSMenuItem) {
        guard let filterID = sender.representedObject as? PacketCustomFilter.ID else {
            return
        }
        delegate?.packetWiresharkFilterViewController(self, didRequestOverrideCustomFilter: filterID)
    }

    private func presentSaveNameAlert() {
        let alert = NSAlert()
        alert.messageText = "Save Wireshark Filter"
        alert.informativeText = "Choose a name for this display filter."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Filter name"
        alert.accessoryView = nameField
        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let name = try? PacketCustomFilterService.normalizedName(nameField.stringValue) else {
                return
            }
            guard let self else {
                return
            }
            self.delegate?.packetWiresharkFilterViewController(self, didRequestSaveNamed: name)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    @objc private func openSyntaxHelp(_ sender: Any?) {
        guard let url = URL(string: "https://www.wireshark.org/docs/wsug_html_chunked/ChWorkBuildDisplayFilterSection.html") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func hideFilter(_ sender: Any?) {
        delegate?.packetWiresharkFilterViewControllerDidRequestHide(self)
    }
}
