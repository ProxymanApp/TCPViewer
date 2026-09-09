//
//  TCPViewerWorkspaceImporter.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import AppKit
import PcapPlusPlusCore

/// Serializes placement sheets and imports without keeping a destination pane alive.
final class TCPViewerWorkspaceImporter: TCPViewerWorkspaceControllerDelegate {
    static let cancelledError = TCPViewerCoreError(code: .operationCancelled, message: "Capture import was cancelled.")
    private struct Request {
        let id = UUID()
        let urls: [URL]
        let targetID: UUID?
        weak var targetTab: TCPViewerWorkspaceTab?
        let asksPlacement: Bool
        let presentsErrors: Bool
        let completion: (TCPViewerCaptureImportResult) -> Void
    }

    private weak var windowController: TCPViewerWindowController?
    private var pending: [Request] = []
    private var active: Request?
    private var staging: TCPViewerCaptureWorkspace?
    private var sheet: NSWindow?
    private var progressLabel: NSTextField?

    init(windowController: TCPViewerWindowController) { self.windowController = windowController }

    func open(_ urls: [URL], automaticNewTab: Bool, completion: @escaping (TCPViewerCaptureImportResult) -> Void) {
        let supported = urls.filter(TCPViewerCaptureFileImportPolicy.isSupportedCaptureFileURL)
        let sessionCount = supported.filter(TCPViewerCaptureFileImportPolicy.isSessionFileURL).count
        guard !supported.isEmpty, sessionCount == 0 || supported.count == 1 else {
            completion(TCPViewerCaptureImportResult(importedURLs: [], error: TCPViewerCoreError(
                code: .offlineFileOpenFailed, message: "Choose capture files or one TCPViewer session. Sessions must open alone.")))
            return
        }
        pending.append(Request(urls: supported, targetID: windowController?.selectedTabID, targetTab: windowController?.selectedTab,
                               asksPlacement: Self.shouldAskForPlacement(tabCount: windowController?.tabs.count ?? 0, automaticNewTab: automaticNewTab),
                               presentsErrors: !automaticNewTab, completion: completion))
        startNext()
    }

    static func shouldAskForPlacement(tabCount: Int, automaticNewTab: Bool) -> Bool {
        !automaticNewTab && tabCount >= 2
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty, let owner = windowController else { return }
        let request = pending.removeFirst()
        active = request
        guard request.asksPlacement, let window = owner.window else { load(request, replacing: nil); return }
        let alert = NSAlert()
        alert.messageText = "Open Capture?"
        alert.informativeText = "Replace the current tab or open the capture in a new tab. Export the current session first to keep your changes."
        alert.addButton(withTitle: "Replace Current Tab")
        alert.addButton(withTitle: "Open in New Tab")
        alert.addButton(withTitle: "Cancel")
        sheet = alert.window
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.active?.id == request.id else { return }
            self.sheet = nil
            if response == .alertFirstButtonReturn { self.load(request, replacing: request.targetID) }
            else if response == .alertSecondButtonReturn { self.load(request, replacing: nil) }
            else { self.finish(request, result: .init(importedURLs: [], error: Self.cancelledError)) }
        }
    }

    // Staging owns only the source; no table or inspector is constructed until placement commits.
    private func load(_ request: Request, replacing targetID: UUID?) {
        guard let owner = windowController, active?.id == request.id else { return }
        if targetID != nil, !owner.tabs.contains(where: { $0 === request.targetTab }) {
            finish(request, result: .init(importedURLs: [], error: Self.cancelledError)); return
        }
        let source = owner.makeOfflineWorkspace()
        staging = source
        source.subscribe(self)
        if request.presentsErrors { showProgress() }
        source.controller.importDocumentsWithResult(at: request.urls) { [weak self, weak source] result in
            guard let self, let source, self.active?.id == request.id, self.staging === source else { return }
            self.dismissSheet()
            var finalResult = result
            if targetID != nil, self.windowController?.tabs.contains(where: { $0 === request.targetTab }) != true {
                self.finish(request, result: .init(importedURLs: [], error: Self.cancelledError)); return
            }
            if !result.importedURLs.isEmpty {
                let title = request.urls.count == 1 ? request.urls[0].lastPathComponent : "\(result.importedURLs.count) Capture Files"
                if self.windowController?.placeImportedWorkspace(source, title: title, replacing: targetID) == true {
                    finalResult.packetCount = source.controller.snapshot.packetIngestState.totalPacketCount
                    source.unsubscribe(self)
                    self.staging = nil
                    result.importedURLs.forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
                } else { finalResult = .init(importedURLs: [], error: Self.cancelledError) }
            }
            if let error = finalResult.error, request.presentsErrors,
               (error as? TCPViewerCoreError)?.code != .operationCancelled {
                NSApp.presentError(error)
            }
            self.finish(request, result: finalResult)
        }
    }

    private func finish(_ request: Request, result: TCPViewerCaptureImportResult) {
        guard active?.id == request.id else { return }
        dismissSheet()
        releaseStaging()
        active = nil
        if windowController?.tabs.isEmpty == true { windowController?.newWorkspaceTab(nil) }
        request.completion(result)
        startNext()
    }

    func cancelAll() {
        let requests = active.map { [$0] } ?? []
        let queued = pending
        active = nil
        pending.removeAll()
        dismissSheet()
        releaseStaging()
        (requests + queued).forEach { $0.completion(.init(importedURLs: [], error: Self.cancelledError)) }
    }

    private func releaseStaging() {
        guard let source = staging else { return }
        staging = nil
        source.unsubscribe(self)
        source.close { [source] _ in _ = source }
    }

    @objc private func cancelImport() {
        guard let request = active else { return }
        finish(request, result: .init(importedURLs: [], error: Self.cancelledError))
    }

    private func showProgress() {
        guard let window = windowController?.window else { return }
        let label = NSTextField(labelWithString: "Opening capture…")
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancelImport))
        let stack = NSStackView(views: [label, indicator, button])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 130)
        let controller = NSViewController()
        controller.view = stack
        let sheet = NSWindow(contentViewController: controller)
        self.sheet = sheet
        progressLabel = label
        window.beginSheet(sheet)
    }

    private func dismissSheet() {
        if let sheet { sheet.sheetParent?.endSheet(sheet); sheet.orderOut(nil) }
        sheet = nil
        progressLabel = nil
    }

    func tcpViewerWorkspaceControllerDidChange(_ controller: TCPViewerWorkspaceController) {
        progressLabel?.stringValue = controller.snapshot.sessionImportState.isPresented
            ? controller.snapshot.sessionImportState.message : controller.snapshot.documentState.statusMessage
    }
}
