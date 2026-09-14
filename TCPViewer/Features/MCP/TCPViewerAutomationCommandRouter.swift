//
//  TCPViewerAutomationCommandRouter.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 13/9/26.
//

import AppKit
import PcapPlusPlusCore

// Both transports resolve one workspace before dispatching asynchronous app work.
enum TCPViewerAutomationCommandRouter {
    typealias Values = [String: TCPViewerMCPValue]
    typealias Completion = (TCPViewerMCPResponse) -> Void

    static func route(_ request: TCPViewerMCPRequest, preferredSource: (any TCPViewerMCPDataSource)?,
                      redactionEnabled: @escaping () -> Bool, completion: @escaping Completion,
                      legacy: @escaping (any TCPViewerMCPDataSource, @escaping Completion) -> Void) {
        let redactor = TCPViewerMCPSensitiveDataRedactor()
        let finish: Completion = { response in
            DispatchQueue.main.async {
                guard redactionEnabled() else { completion(response); return }
                if var data = response.data {
                    if request.command == TCPViewerMCPCommand.followStream.rawValue {
                        data["payload_redacted"] = .bool(true)
                        if let records = data["records"]?.arrayValue {
                            data["records"] = .array(records.map { value in
                                guard case .object(var entry) = value else { return value }
                                entry.removeValue(forKey: "data")
                                return .object(entry)
                            })
                        }
                    }
                    completion(TCPViewerMCPResponse(success: response.success, data: data.mapValues { redactor.redact($0) }, error: response.error.map(redactor.redact)))
                }
                else { completion(.failure(redactor.redact(response.error ?? "The command failed."))) }
            }
        }
        do {
            let command = try require(TCPViewerMCPCommand(rawValue: request.command), "Unsupported command.")
            let preferred = (preferredSource as? TCPViewerWorkspaceAutomationSource)?.windowController
            var windows = TCPViewerMCPServiceProvider.shared.workspaceSources.compactMap(\.windowController)
            if let preferred, !windows.contains(where: { $0 === preferred }) { windows.append(preferred) }
            let workspaceID = try request.automationID("workspace_id")
            let tabID = try request.automationID("tab_id")
            let paneID = try request.automationID("pane_id")
            if command == .listWorkspaces {
                guard workspaceID == nil, tabID == nil, paneID == nil else { throw invalid("list_workspaces does not accept target selectors.") }
                finish(.success(["workspaces": .array(windows.map { .object(workspaceData($0)) })])); return
            }
            let candidates = windows.filter { window in
                (workspaceID == nil || window.automationID == workspaceID) &&
                (tabID == nil || window.tabs.contains { $0.id == tabID }) &&
                (paneID == nil || window.tabs.contains { $0.primaryPaneID == paneID || $0.secondaryPaneID == paneID })
            }
            let window = try require(
                workspaceID == nil && tabID == nil && paneID == nil ? preferred ?? candidates.last : candidates.first,
                "The requested workspace, tab, or pane was not found."
            )
            let tab = window.tabs.first { item in
                (tabID == nil || item.id == tabID) &&
                (paneID == nil || item.primaryPaneID == paneID || item.secondaryPaneID == paneID) &&
                (tabID != nil || paneID != nil || item.id == window.selectedTabID)
            }
            if (tabID != nil || paneID != nil), tab == nil {
                throw invalid("The tab and pane selectors do not identify the same target.")
            }
            if command == .listTabs {
                finish(.success(workspaceData(window))); return
            }
            if command == .createTab {
                guard tabID == nil, paneID == nil else { throw invalid("create_tab accepts only workspace_id as a target.") }
                let newTab = try window.createAutomationTab(selecting: request.automationBool("select", default: false))
                finish(.success(tabData(newTab, window: window))); return
            }
            if command == .importCapture {
                guard paneID == nil else { throw invalid("Import targets a tab, not a pane.") }
                try importCapture(request, window: window, replacement: tabID != nil ? tab : nil, completion: finish)
                return
            }
            let target = try require(tab, "The requested tab was not found.")
            let resolvedPaneID = paneID ?? target.focusedPaneID
            switch command {
            case .selectTab:
                window.selectTab(target.id)
                finish(.success(tabData(target, window: window))); return
            case .moveTab:
                let index = try request.automationInt("index", default: -1, range: 0...max(0, window.tabs.count - 1))
                try window.moveAutomationTab(target, index: index)
                finish(.success(tabData(target, window: window))); return
            case .closeTab:
                guard try request.automationBool("confirm", default: false) else { throw invalid("Closing a tab requires confirm=true.") }
                window.closeAutomationTab(target) { result in
                    finish(response(result.map { ["closed_tab_id": .string(target.id.uuidString.lowercased())] }))
                }
                return
            case .setSplitView:
                guard request.value("enabled") != nil else { throw invalid("enabled is required.") }
                try window.setAutomationSplit(request.automationBool("enabled", default: false), tab: target)
                finish(.success(tabData(target, window: window))); return
            case .focusPane:
                window.focusAutomationPane(resolvedPaneID, tab: target)
                finish(.success(tabData(target, window: window))); return
            default: break
            }
            let model = try require(target.automationModel(id: resolvedPaneID, factory: window.makeAutomationModel), "The pane is closed.")
            let scope = try request.automationEnum("scope", values: ["all", "displayed"], default: "all")
            if command == .getOverviewStatistics, scope != "all" { throw invalid("Overview statistics use the complete source. Use scope=all.") }
            let source = TCPViewerWorkspaceAutomationSource(windowController: window).bound(to: target, model: model, displayed: scope == "displayed")
            try model.beginAutomation()
            let sourceIdentity = model.captureSnapshotForCommands.packetIngestState.backingIdentity
            let lineage = model.captureSnapshotForCommands.packetIngestState.packetLineageRevision
            let changesCapture = [.startCapture, .clearPackets].contains(command)
            let done: Completion = { result in
                DispatchQueue.main.async {
                    let state = model.captureSnapshotForCommands.packetIngestState
                    let valid = source.isValid && (changesCapture || (state.backingIdentity == sourceIdentity && state.packetLineageRevision == lineage))
                    if valid, target.focusedPaneID == resolvedPaneID { target.updateAutomaticTitle(from: model) }
                    model.endAutomation()
                    finish(valid ? result : .failure("The target closed or its capture was replaced during the command."))
                }
            }
            let perform = {
                do {
                    switch command {
                    case .getPane:
                        done(.success(paneData(model, id: resolvedPaneID, tab: target, window: window)))
                    case .listSources:
                        let items = sourceItems(model.snapshot.sourceListSnapshot)
                        let offset = try request.automationInt("offset", default: 0, range: 0...Int.max)
                        let limit = try request.automationInt("limit", default: 50, range: 1...500)
                        let page = Array(items.dropFirst(offset).prefix(limit))
                        done(.success(["sources": .array(page.map { .object(sourceData($0)) }),
                                       "total_count": .int(items.count), "returned_count": .int(page.count),
                                       "next_offset": offset + page.count < items.count ? .int(offset + page.count) : .null]))
                    case .updatePane:
                        try updatePane(request, model: model) { result in
                            done(response(result.map { paneData(model, id: resolvedPaneID, tab: target, window: window) }))
                        }
                    case .getOverviewStatistics, .getEndpointStatistics:
                        try TCPViewerAutomationAnalysisJob.start(request, model: model, isValid: { source.isValid }, completion: done)
                    case .followStream:
                        try follow(request, model: model, redactionEnabled: redactionEnabled, completion: done)
                    case .exportSession:
                        let destination = try sessionDestination(request)
                        model.exportTCPViewSession(to: destination) { result in
                            done(response(result.map { ["path": .string(destination.path)] }))
                        }
                    default:
                        legacy(source, done)
                    }
                } catch { done(.failure(error.localizedDescription)) }
            }
            if command != .updatePane && (scope == "displayed" || command == .listSources || command == .getPane) {
                model.prepareAutomationScope { result in
                    switch result { case .success: perform(); case .failure(let error): done(.failure(error.localizedDescription)) }
                }
            } else { perform() }
        } catch { finish(.failure(error.localizedDescription)) }
    }

    static func workspaceData(_ window: TCPViewerWindowController) -> Values {
        ["workspace_id": .string(window.automationID.uuidString.lowercased()),
         "selected_tab_id": window.selectedTabID.map { .string($0.uuidString.lowercased()) } ?? .null,
         "tabs": .array(window.tabs.map { .object(tabData($0, window: window)) })]
    }

    static func tabData(_ tab: TCPViewerWorkspaceTab, window: TCPViewerWindowController) -> Values {
        let panes = [(tab.primaryPaneID, "primary")] + (tab.secondaryPaneID.map { [($0, "secondary")] } ?? [])
        return ["workspace_id": .string(window.automationID.uuidString.lowercased()),
                "tab_id": .string(tab.id.uuidString.lowercased()), "title": .string(tab.displayTitle),
                "index": .int(window.tabs.firstIndex { $0 === tab } ?? 0),
                "source": .string(tab.isOffline ? "offline" : "live"),
                "selected": .bool(window.selectedTab === tab), "split_enabled": .bool(tab.isSplitViewVisible),
                "focused_pane_id": .string(tab.focusedPaneID.uuidString.lowercased()),
                "panes": .array(panes.map { id, role in .object(["pane_id": .string(id.uuidString.lowercased()), "role": .string(role)]) })]
    }

    static func paneData(_ model: NetworkInspectorViewModel, id: UUID, tab: TCPViewerWorkspaceTab, window: TCPViewerWindowController) -> Values {
        let state = model.makeSplitPaneState()
        return ["workspace_id": .string(window.automationID.uuidString.lowercased()),
                "tab_id": .string(tab.id.uuidString.lowercased()), "pane_id": .string(id.uuidString.lowercased()),
                "mode": .string(state.workspaceMode.rawValue), "display_filter": .string(state.displayFilterText),
                "filter_mode": .string(state.filterMode.rawValue),
                "structured_filter": structuredValue(state.structuredFilterGroup),
                "wireshark_filter": .string(state.wiresharkFilterState.draftExpression),
                "quick_filters": .array(state.quickFilterSelection.activeIDs.map { .string($0.rawValue) }),
                "available_quick_filters": .array(PacketQuickFilterID.allCases.map { .string($0.rawValue) }),
                "source_id": model.snapshot.sourceListSnapshot.item(for: state.selectedSourceListSelection).map { .string($0.id) } ?? .null,
                "endpoint": state.endpointStatisticsFilter.map { .object(["group": .string($0.group.rawValue), "key": .string($0.key)]) } ?? .null,
                "packet_id": state.selectedPacketID.map { .string(String($0)) } ?? .null,
                "packet_count": .int(model.captureSnapshotForCommands.packetIngestState.totalPacketCount),
                "displayed_packet_count": .int(model.snapshot.base.navigationState.visiblePacketIDs.count)]
    }

    // Validate the complete update before changing any pane preference.
    static func updatePane(_ request: TCPViewerMCPRequest, model: NetworkInspectorViewModel,
                           completion: @escaping (Result<Void, Error>) -> Void) throws {
        let mode = try request.automationString("mode")
        if let mode, !["packets", "overview"].contains(mode) { throw invalid("mode must be packets or overview.") }
        let finalMode = mode.flatMap(NetworkInspectorWorkspaceMode.init(rawValue:)) ?? model.makeSplitPaneState().workspaceMode
        let text = try request.automationString("display_filter")
        let wireshark = try request.automationString("wireshark_filter")
        let sourceID = try request.automationString("source_id")
        let selection = try sourceID.map { id in
            try require(sourceItems(model.snapshot.sourceListSnapshot).first { $0.id == id }?.selection, "The source_id was not found. Use list_sources.")
        }
        let group = try request.value("structured_filter").map(parseStructuredGroup)
        if group != nil && wireshark != nil { throw invalid("Choose structured_filter or wireshark_filter, not both.") }
        let quick = try request.value("quick_filters").map { value -> PacketQuickFilterSelection in
            guard let items = value.arrayValue, items.count <= PacketQuickFilterID.allCases.count else { throw invalid("quick_filters must be an array of supported filter IDs.") }
            let ids = try items.map { try require($0.stringValue.flatMap(PacketQuickFilterID.init(rawValue:)), "Unknown quick filter.") }
            return PacketQuickFilterSelection(selectedIDs: Set(ids))
        }
        let packetID: PacketSummary.ID?
        if let value = request.value("packet_id"), value != .null {
            packetID = try require(value.stringValue.flatMap(UInt64.init), "packet_id must be an unsigned decimal string or null.")
            guard model.captureSnapshotForCommands.packetIngestState.packet(withID: packetID) != nil else { throw invalid("The packet was not found in this capture.") }
        } else { packetID = nil }
        let endpoint = try request.value("endpoint").flatMap { value -> EndpointStatisticsRowID? in
            if value == .null { return nil }
            guard case .object(let object) = value,
                  let group = object["group"]?.stringValue.flatMap(EndpointStatisticsGroup.init(rawValue:)),
                  let key = object["key"]?.stringValue, key.utf8.count <= 4096 else { throw invalid("endpoint requires a valid group and key.") }
            return EndpointStatisticsRowID(group: group, key: key)
        }
        guard !model.automationMutationIsRunning else { throw invalid("A pane update is already running. Retry when it finishes.") }
        model.automationMutationIsRunning = true
        let finish: (Result<Void, Error>) -> Void = { result in
            model.automationMutationIsRunning = false
            completion(result)
        }
        let apply = {
            guard !model.isClosed else { finish(.failure(invalid("The pane is closed."))); return }
            if let selection { model.clearEndpointStatisticsFilter(); model.selectSourceList(selection) }
            if request.value("endpoint") == .null { model.clearEndpointStatisticsFilter() }
            if let endpoint { _ = model.showRelatedPackets(forEndpoint: endpoint) }
            if let text { model.updateDisplayFilterText(text) }
            model.setAutomationFilters(group: group, quick: quick, wireshark: wireshark) { result in
                if case .success = result {
                    if request.value("packet_id") != nil { model.selectPacket(packetID) }
                    model.selectWorkspaceMode(finalMode)
                }
                finish(result)
            }
        }
        if let expression = wireshark ?? group?.wiresharkExpression, !expression.isEmpty {
            model.captureWorkspace.controller.validateDisplayFilter(expression) { validation in
                DispatchQueue.main.async {
                    if validation.isApplicable { apply() }
                    else { finish(.failure(invalid(validation.diagnostics.first?.message ?? "The Wireshark filter is invalid."))) }
                }
            }
        } else { apply() }
    }

    static func structuredValue(_ group: PacketStructuredFilterGroup) -> TCPViewerMCPValue {
        .object(["operator": .string(group.operator.rawValue), "filters": .array(group.filters.map { filter in
            .object(["id": .string(filter.id), "query": .string(filter.query.rawValue), "condition": .string(filter.condition.rawValue),
                     "text": .string(filter.text), "is_enabled": .bool(filter.isEnabled)])
        })])
    }

    static func parseStructuredGroup(_ value: TCPViewerMCPValue) throws -> PacketStructuredFilterGroup {
        guard case .object(let object) = value, let items = object["filters"]?.arrayValue,
              items.count <= PacketStructuredFilterGroup.maxFilterCount,
              let operation = PacketStructuredFilterGroupOperator(rawValue: object["operator"]?.stringValue ?? "and") else {
            throw invalid("structured_filter requires operator=and|or and at most five filters.")
        }
        let filters = try items.map { item -> PacketStructuredFilter in
            guard case .object(let fields) = item,
                  let query = fields["query"]?.stringValue.flatMap(PacketStructuredFilterQuery.init(rawValue:)),
                  let condition = fields["condition"]?.stringValue.flatMap(PacketStructuredFilterCondition.init(rawValue:)),
                  let text = fields["text"]?.stringValue, text.utf8.count <= 4096 else { throw invalid("Invalid structured filter query, condition, or text.") }
            if let value = fields["is_enabled"], value.boolValue == nil { throw invalid("is_enabled must be boolean.") }
            if condition == .matchesRegex || condition == .notMatchesRegex {
                guard (try? NSRegularExpression(pattern: text, options: [.caseInsensitive])) != nil else { throw invalid("The structured filter contains an invalid regular expression.") }
            }
            return PacketStructuredFilter(id: fields["id"]?.stringValue ?? UUID().uuidString, query: query, condition: condition,
                                          text: text, isEnabled: fields["is_enabled"]?.boolValue ?? true)
        }
        if filters.count > 1 && filters.contains(where: { $0.query == .anyText }) { throw invalid("A Wireshark filter must be the only structured filter.") }
        return PacketStructuredFilterGroup(filters: filters, operator: operation)
    }

    static func sourceItems(_ snapshot: PacketSourceListSnapshot) -> [PacketSourceListItem] {
        func flatten(_ items: [PacketSourceListItem]) -> [PacketSourceListItem] {
            items.flatMap { ($0.selection == nil ? [] : [$0]) + flatten($0.children) }
        }
        return flatten(snapshot.roots)
    }

    static func sourceData(_ item: PacketSourceListItem) -> Values {
        ["source_id": .string(item.id), "title": .string(item.title), "packet_count": item.count.map(TCPViewerMCPValue.int) ?? .null]
    }

    // Stage imports independently, then commit only if the destination is still the same tab object.
    static func importCapture(_ request: TCPViewerMCPRequest, window: TCPViewerWindowController,
                              replacement: TCPViewerWorkspaceTab?, completion: @escaping Completion) throws {
        guard let items = request.array("paths"), !items.isEmpty, items.count <= 100 else { throw invalid("paths requires 1 to 100 capture paths.") }
        let urls = try items.map { value -> URL in
            guard let path = value.stringValue, path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else { throw invalid("Import paths must be absolute.") }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard TCPViewerCaptureFileImportPolicy.isSupportedCaptureFileURL(url), metadata.isRegularFile == true, metadata.isSymbolicLink != true else { throw invalid("Import requires a regular capture file, not a symbolic link.") }
            return url
        }
        if urls.contains(where: TCPViewerCaptureFileImportPolicy.isSessionFileURL), urls.count != 1 { throw invalid("A tcpviewsession must be imported by itself.") }
        if replacement != nil, try !request.automationBool("confirm", default: false) { throw invalid("Replacing a tab requires confirm=true.") }
        guard replacement != nil || window.canCreateAdditionalTab else { throw invalid("TCP Viewer PRO is required for additional tabs.") }
        let selecting = try request.automationBool("select", default: replacement == nil)
        let source = window.makeOfflineWorkspace()
        source.suppressesImportPresentation = true
        let importID = window.registerAutomationImport(source, target: replacement) { completion(.failure("The import target was closed or replaced.")) }
        source.controller.importDocumentsWithResult(at: urls) { result in
            DispatchQueue.main.async {
                guard window.finishAutomationImport(importID) else { return }
                let targetValid = replacement.map { old in window.tabs.contains { $0 === old } } ?? true
                guard targetValid, !result.importedURLs.isEmpty else {
                    source.close()
                    completion(.failure(result.error?.localizedDescription ?? "The import target was closed or replaced.")); return
                }
                let title = urls.count == 1 ? urls[0].lastPathComponent : "\(result.importedURLs.count) Capture Files"
                guard window.placeImportedWorkspace(source, title: title, replacing: replacement?.id, selecting: selecting, allowsPrompt: false),
                      let tab = window.tabs.first(where: { $0.source === source }) else {
                    source.close(); completion(.failure("The workspace closed or tab creation is no longer authorized.")); return
                }
                var data = tabData(tab, window: window)
                data["imported_files"] = .array(result.importedURLs.map { .string($0.path) })
                data["imported_file_count"] = .int(result.importedURLs.count)
                data["packet_count"] = .int(source.controller.snapshot.packetIngestState.totalPacketCount)
                if let error = result.error {
                    completion(TCPViewerMCPResponse(success: false, data: data, error: error.localizedDescription))
                } else { completion(.success(data)) }
            }
        }
    }

    static func sessionDestination(_ request: TCPViewerMCPRequest) throws -> URL {
        let path = try require(request.automationString("path"), "path is required.")
        guard path.hasPrefix("/"), !path.contains("\0") else { throw invalid("path must be absolute.") }
        var url = URL(fileURLWithPath: path).standardizedFileURL
        if url.pathExtension.isEmpty { url.appendPathExtension("tcpviewsession") }
        guard url.pathExtension.lowercased() == "tcpviewsession" else { throw invalid("The destination must end in .tcpviewsession.") }
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw invalid("The destination directory must exist and be writable.") }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]) {
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw invalid("The destination must be a regular file, not a symbolic link.") }
            guard try request.automationBool("overwrite", default: false) else { throw invalid("The destination exists. Set overwrite=true.") }
        }
        return url
    }

    static func follow(_ request: TCPViewerMCPRequest, model: NetworkInspectorViewModel,
                       redactionEnabled: @escaping () -> Bool, completion: @escaping Completion) throws {
        let id = try require(request.string("packet_id").flatMap(UInt64.init), "packet_id is required as an unsigned decimal string.")
        let transport = try request.automationEnum("protocol", values: ["auto", "tcp", "udp"], default: "auto")
        let direction = try request.automationEnum("direction", values: ["both", "client-to-server", "server-to-client"], default: "both")
        let encoding = try request.automationEnum("encoding", values: ["text", "hex", "base64"], default: "text")
        let bytes = try request.automationInt("max_bytes", default: 4 * 1024 * 1024, range: 1...(4 * 1024 * 1024))
        let records = try request.automationInt("max_records", default: 10_000, range: 1...10_000)
        let selectedDirection: FollowStreamDirection? = direction == "both" ? nil : direction == "client-to-server" ? .clientToServer : .serverToClient
        model.followStream(containing: id, streamProtocol: FollowStreamProtocol(rawValue: transport),
                           limits: FollowStreamLimits(maximumCandidatePacketCount: 250_000, maximumPayloadBytes: bytes,
                                                      maximumRecordCount: records, includedDirection: selectedDirection),
                           progress: nil, shouldCancel: nil) { result in
            DispatchQueue.main.async {
                completion(response(result.map { stream in
                    TCPViewerAutomationStreamSerializer.data(stream, direction: direction, encoding: encoding,
                                                              maximumBytes: bytes, maximumRecords: records,
                                                              redacted: redactionEnabled())
                }))
            }
        }
    }

    static func invalid(_ message: String) -> Error { TCPViewerMCPDataSourceError.invalidState(message) }
    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw invalid(message) }
        return value
    }
    static func response(_ result: Result<Values, Error>) -> TCPViewerMCPResponse {
        switch result { case .success(let data): .success(data); case .failure(let error): .failure(error.localizedDescription) }
    }
}

extension TCPViewerMCPRequest {
    func automationString(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard let text = value.stringValue, text.utf8.count <= 4096 else { throw TCPViewerAutomationCommandRouter.invalid("\(key) must be a string of at most 4096 bytes.") }
        return text
    }
    func automationID(_ key: String) throws -> UUID? {
        guard let text = try automationString(key) else { return nil }
        return try TCPViewerAutomationCommandRouter.require(UUID(uuidString: text), "\(key) must be a UUID.")
    }
    func automationBool(_ key: String, default fallback: Bool) throws -> Bool {
        guard let value = value(key) else { return fallback }
        return try TCPViewerAutomationCommandRouter.require(value.boolValue, "\(key) must be boolean.")
    }
    func automationInt(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        let number = try value(key).map { try TCPViewerAutomationCommandRouter.require($0.intValue, "\(key) must be an integer.") } ?? fallback
        guard range.contains(number) else { throw TCPViewerAutomationCommandRouter.invalid("\(key) must be in \(range).") }
        return number
    }
    func automationEnum(_ key: String, values: [String], default fallback: String) throws -> String {
        let text = try automationString(key) ?? fallback
        guard values.contains(text) else { throw TCPViewerAutomationCommandRouter.invalid("\(key) must be one of: \(values.joined(separator: ", ")).") }
        return text
    }
}
