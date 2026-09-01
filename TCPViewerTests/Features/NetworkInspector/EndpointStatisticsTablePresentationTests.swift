//
//  EndpointStatisticsTablePresentationTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/9/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct EndpointStatisticsTablePresentationTests {
    @Test func numericSortUsesRawValuesAndStableEndpointKeys() {
        let rows = [
            Self.makeRow(key: "charlie", address: "10.0.0.3", bytes: 40),
            Self.makeRow(key: "bravo", address: "10.0.0.2", bytes: 90),
            Self.makeRow(key: "alpha", address: "10.0.0.1", bytes: 90),
        ]

        let result = EndpointStatisticsTablePresenter.presentation(
            rows: rows,
            searchText: "",
            sort: .busiestFirst
        )

        #expect(result.rows.map { $0.id.key } == ["alpha", "bravo", "charlie"])
        #expect(result.totals.bytes == 220)
    }

    @Test func missingStringValuesStayLastInBothSortDirections() {
        let rows = [
            Self.makeRow(key: "missing", domain: nil),
            Self.makeRow(key: "beta", domain: "beta.example"),
            Self.makeRow(key: "alpha", domain: "alpha.example"),
        ]

        let ascending = EndpointStatisticsTablePresenter.presentation(
            rows: rows,
            searchText: "",
            sort: EndpointStatisticsTableSort(column: .domain, isAscending: true)
        )
        let descending = EndpointStatisticsTablePresenter.presentation(
            rows: rows,
            searchText: "",
            sort: EndpointStatisticsTableSort(column: .domain, isAscending: false)
        )

        #expect(ascending.rows.map { $0.id.key } == ["alpha", "beta", "missing"])
        #expect(descending.rows.map { $0.id.key } == ["beta", "alpha", "missing"])
    }

    @Test func multiTermSearchMatchesAcrossDifferentIdentityColumns() {
        let rows = [
            Self.makeRow(
                key: "one",
                address: "93.184.216.34",
                port: "443",
                client: "Example Browser",
                domain: "api.example.com"
            ),
            Self.makeRow(
                key: "two",
                address: "1.1.1.1",
                port: "53",
                client: "Resolver",
                domain: "cloudflare-dns.com"
            ),
        ]

        let result = EndpointStatisticsTablePresenter.presentation(
            rows: rows,
            searchText: "browser 443 API",
            sort: .busiestFirst
        )

        #expect(result.rows.map { $0.id.key } == ["one"])
        #expect(result.unfilteredRowCount == 2)
    }

    @Test func csvQuotesSpecialValuesAndProtectsFormulaAfterWhitespace() {
        let row = Self.makeRow(
            key: "formula",
            client: "Browser, \"Beta\"",
            domain: "  =SUM(A1:A2)",
            bytes: 42
        )

        let csv = EndpointStatisticsTableExportFormatter.csv(
            rows: [row],
            columns: [.client, .domain, .bytes]
        )

        #expect(csv == "Client,Domain,Bytes\r\n\"Browser, \"\"Beta\"\"\",'  =SUM(A1:A2),42")
    }

    @Test func csvProtectsLeadingTabAndCarriageReturnFormulaBypasses() {
        let tabRow = Self.makeRow(key: "tab", domain: "\tSUM(A1:A2)")
        let carriageReturnRow = Self.makeRow(key: "return", domain: "\rSUM(A1:A2)")

        let csv = EndpointStatisticsTableExportFormatter.csv(
            rows: [tabRow, carriageReturnRow],
            columns: [.domain]
        )

        #expect(csv == "Domain\r\n'\tSUM(A1:A2)\r\n\"'\rSUM(A1:A2)\"")
    }

    @Test func jsonUsesStableLowercaseKeysAndRawNumbers() throws {
        let row = Self.makeRow(key: "json", domain: "api.example", bytes: 42, txPackets: 3)
        let columns: [EndpointStatisticsTableColumn] = [.domain, .bytes, .txPackets]

        let first = EndpointStatisticsTableExportFormatter.json(rows: [row], columns: columns)
        let second = EndpointStatisticsTableExportFormatter.json(rows: [row], columns: columns)
        let data = try #require(first.data(using: String.Encoding.utf8))
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let object = try #require(objects.first)

        #expect(first == second)
        #expect(Set(object.keys) == ["bytes", "domain", "tx_packets"])
        #expect(object["domain"] as? String == "api.example")
        #expect(object["bytes"] as? NSNumber == 42)
        #expect(object["tx_packets"] as? NSNumber == 3)
        #expect(!first.contains("\"42\""))
    }

    @Test func semanticCopySkipsAggregatePlaceholderValues() {
        #expect(EndpointStatisticsSemanticCopyPolicy.copyableValue("api.example") == "api.example")
        #expect(EndpointStatisticsSemanticCopyPolicy.copyableValue(
            EndpointStatisticsRow.multipleValue
        ) == EndpointStatisticsRow.multipleValue)
        #expect(EndpointStatisticsSemanticCopyPolicy.copyableValue(
            EndpointStatisticsRow.multipleValue,
            isAggregatePlaceholder: true
        ) == nil)
        #expect(EndpointStatisticsSemanticCopyPolicy.copyableValue("") == nil)
        #expect(EndpointStatisticsSemanticCopyPolicy.copyableValue(nil) == nil)
    }

    @Test func asyncExportCommitsOnlyWhileClipboardAndGenerationAreCurrent() {
        let token = EndpointStatisticsExportCommitToken(
            generation: 3,
            pasteboardChangeCount: 12
        )

        #expect(EndpointStatisticsExportCommitPolicy.shouldCommit(
            token,
            currentGeneration: 3,
            currentPasteboardChangeCount: 12
        ))
        #expect(!EndpointStatisticsExportCommitPolicy.shouldCommit(
            token,
            currentGeneration: 4,
            currentPasteboardChangeCount: 12
        ))
        #expect(!EndpointStatisticsExportCommitPolicy.shouldCommit(
            token,
            currentGeneration: 3,
            currentPasteboardChangeCount: 13
        ))
    }

    @Test func selectionRestorationUsesThePresentedRowIndex() {
        let rows = [
            Self.makeRow(key: "alpha", bytes: 10),
            Self.makeRow(key: "bravo", bytes: 30),
            Self.makeRow(key: "charlie", bytes: 20),
        ]
        let selectedIDs = EndpointStatisticsSelectionRestoration.selectedRowIDs(
            rows: rows,
            selectedIndexes: IndexSet([0, 2])
        )
        let presentation = EndpointStatisticsTablePresenter.presentation(
            rows: rows,
            searchText: "",
            sort: .busiestFirst
        )

        #expect(EndpointStatisticsSelectionRestoration.rowIndexes(
            for: selectedIDs,
            rowIndexByID: presentation.rowIndexByID
        ) == IndexSet([1, 2]))
        #expect(EndpointStatisticsSelectionRestoration.selectedRowIDs(
            rows: rows,
            selectedIndexes: []
        ).isEmpty)
        #expect(EndpointStatisticsSelectionRestoration.rowIndexes(
            for: [],
            rowIndexByID: presentation.rowIndexByID
        ).isEmpty)
    }

    @Test func contextTargetKeepsEndpointAndColumnAcrossReorder() {
        let alpha = Self.makeRow(key: "alpha", domain: "alpha.example", bytes: 10)
        let bravo = Self.makeRow(key: "bravo", domain: "bravo.example", bytes: 30)
        let context = EndpointStatisticsContextTarget(rowID: bravo.id, column: .domain)
        let reordered = EndpointStatisticsTablePresenter.presentation(
            rows: [alpha, bravo],
            searchText: "",
            sort: .busiestFirst
        )

        #expect(context.resolvedRowIndex(
            rowIndexByID: reordered.rowIndexByID,
            rowCount: reordered.rows.count
        ) == 0)
        #expect(context.column == .domain)
        #expect(context.resolvedRowIndex(
            rowIndexByID: [alpha.id: 0],
            rowCount: 1
        ) == nil)
    }

    @Test func rowSelectionResolvesSparseIndexesAndFormattingCanCancel() throws {
        let rows = (0..<1_024).map { Self.makeRow(key: "row-\($0)", domain: "\($0).example") }
        let selection = EndpointStatisticsRowSelection.indexes(IndexSet([1, 7, 1_500]))
        let selectedRows = try #require(selection.resolvedRows(
            from: rows,
            cancellationToken: EndpointStatisticsCancellationToken()
        ))

        #expect(selectedRows.map { $0.id.key } == ["row-1", "row-7"])
        #expect(EndpointStatisticsTableExportFormatter.csv(
            rows: rows,
            columns: [.domain],
            cancellationToken: EndpointStatisticsCancellationToken(cancelAfterCheckCount: 0)
        ) == nil)
        #expect(EndpointStatisticsTableExportFormatter.json(
            rows: rows,
            columns: [.domain],
            cancellationToken: EndpointStatisticsCancellationToken(cancelAfterCheckCount: 0)
        ) == nil)
        #expect(EndpointStatisticsSemanticValueFormatter.joinedValues(
            rows: rows,
            field: .domain,
            cancellationToken: EndpointStatisticsCancellationToken(cancelAfterCheckCount: 0)
        ) == nil)
    }

    @Test func semanticValueFormattingDeduplicatesOffMainAndUsesMultiplicityFlags() {
        let rows = [
            Self.makeRow(key: "literal", client: EndpointStatisticsRow.multipleValue),
            Self.makeRow(
                key: "aggregate",
                client: EndpointStatisticsRow.multipleValue,
                isClientMultiple: true
            ),
            Self.makeRow(key: "browser-a", client: "Browser"),
            Self.makeRow(key: "browser-b", client: "Browser"),
        ]

        let value = EndpointStatisticsSemanticValueFormatter.joinedValues(
            rows: rows,
            field: .client,
            cancellationToken: EndpointStatisticsCancellationToken()
        )

        #expect(value == "Multiple\nBrowser")
    }

    @Test func semanticSelectionEnablementScansIndexesWithoutMaterializingRows() {
        let rows = [
            Self.makeRow(key: "missing", client: nil),
            Self.makeRow(key: "aggregate", client: "Multiple", isClientMultiple: true),
            Self.makeRow(key: "copyable", client: "Browser"),
        ]

        #expect(!EndpointStatisticsRowSelection.indexes(IndexSet([0, 1])).containsCopyableValue(
            in: rows,
            field: .client
        ))
        #expect(EndpointStatisticsRowSelection.indexes(IndexSet([0, 2])).containsCopyableValue(
            in: rows,
            field: .client
        ))
    }

    @Test func largeFormattersStopAfterMidLoopCancellation() {
        let rows = (0..<1_024).map { Self.makeRow(key: "row-\($0)", domain: "\($0).example") }

        #expect(EndpointStatisticsTableExportFormatter.csv(
            rows: rows,
            columns: [.domain, .bytes],
            cancellationToken: EndpointStatisticsCancellationToken(cancelAfterCheckCount: 2)
        ) == nil)
        #expect(EndpointStatisticsTableExportFormatter.json(
            rows: rows,
            columns: [.domain, .bytes],
            cancellationToken: EndpointStatisticsCancellationToken(cancelAfterCheckCount: 2)
        ) == nil)
        #expect(EndpointStatisticsSemanticValueFormatter.joinedValues(
            rows: rows,
            field: .domain,
            cancellationToken: EndpointStatisticsCancellationToken(cancelAfterCheckCount: 2)
        ) == nil)
    }
}

struct EndpointStatisticsPresentationCommitPolicyTests {
    @Test func slowPresentationsReceiveABoundedCooldown() {
        #expect(EndpointStatisticsPresentationCadence.cooldown(after: 0.1) == 0)
        #expect(EndpointStatisticsPresentationCadence.cooldown(after: 0.5) == 0.5)
        #expect(EndpointStatisticsPresentationCadence.cooldown(after: 5) == 2)
    }

    @Test func footerAddsUnclassifiedBytesOnlyWhenPresent() {
        var totals = EndpointStatisticsTotals.zero
        totals.bytes = 80
        totals.txBytes = 30
        totals.rxBytes = 20

        let knownDirection = EndpointStatisticsFooterFormatter.trafficParts(
            totals: totals,
            formatBytes: { "\($0) B" }
        )
        totals.unclassifiedBytes = 30
        let mixedDirection = EndpointStatisticsFooterFormatter.trafficParts(
            totals: totals,
            formatBytes: { "\($0) B" }
        )

        #expect(knownDirection == ["80 B", "Tx 30 B", "Rx 20 B"])
        #expect(mixedDirection == ["80 B", "Tx 30 B", "Rx 20 B", "Unclassified 30 B"])
    }

    @Test func continuousAllPacketAppendsCommitThenRequestAFresherResult() {
        let context = Self.context(usesDisplayedPackets: false)

        let decision = EndpointStatisticsPresentationCommitPolicy.decision(
            requestContext: context,
            currentContext: context,
            requestIngestCursor: Self.cursor(revision: 1, lineage: 7, count: 10),
            currentIngestCursor: Self.cursor(revision: 9, lineage: 7, count: 90),
            requestDisplayedCursor: nil,
            currentDisplayedCursor: nil,
            requestClassificationRevision: 1,
            currentClassificationRevision: 1,
            isWaitingForDisplayFilter: false
        )

        #expect(decision == .commitAndRefresh)
    }

    @Test func displayedPresentationIgnoresUnrelatedRawIngestUpdates() {
        let context = Self.context(usesDisplayedPackets: true)
        let displayedCursor = Self.cursor(revision: 3, lineage: 4, count: 20)

        let decision = EndpointStatisticsPresentationCommitPolicy.decision(
            requestContext: context,
            currentContext: context,
            requestIngestCursor: Self.cursor(revision: 1, lineage: 7, count: 10),
            currentIngestCursor: Self.cursor(revision: 9, lineage: 7, count: 90),
            requestDisplayedCursor: displayedCursor,
            currentDisplayedCursor: displayedCursor,
            requestClassificationRevision: 1,
            currentClassificationRevision: 1,
            isWaitingForDisplayFilter: false
        )

        #expect(decision == .commit)
    }

    @Test func replacementLineageAndQueryChangesDiscardOldResults() {
        let requestContext = Self.context(usesDisplayedPackets: true)
        let changedContext = Self.context(usesDisplayedPackets: true, group: .domains)

        let changedLineage = EndpointStatisticsPresentationCommitPolicy.decision(
            requestContext: requestContext,
            currentContext: requestContext,
            requestIngestCursor: nil,
            currentIngestCursor: nil,
            requestDisplayedCursor: Self.cursor(revision: 1, lineage: 1, count: 10),
            currentDisplayedCursor: Self.cursor(revision: 2, lineage: 2, count: 10),
            requestClassificationRevision: 1,
            currentClassificationRevision: 1,
            isWaitingForDisplayFilter: false
        )
        let changedQuery = EndpointStatisticsPresentationCommitPolicy.decision(
            requestContext: requestContext,
            currentContext: changedContext,
            requestIngestCursor: nil,
            currentIngestCursor: nil,
            requestDisplayedCursor: Self.cursor(revision: 1, lineage: 1, count: 10),
            currentDisplayedCursor: Self.cursor(revision: 1, lineage: 1, count: 10),
            requestClassificationRevision: 1,
            currentClassificationRevision: 1,
            isWaitingForDisplayFilter: false
        )

        #expect(changedLineage == .discard)
        #expect(changedQuery == .discard)
    }

    @Test func rowActionsRequireTheCommittedGroupScopeAndLineage() {
        let committed = EndpointStatisticsActionState(
            context: Self.context(usesDisplayedPackets: false),
            classificationRevision: 1
        )
        let changedGroup = EndpointStatisticsActionState(
            context: Self.context(usesDisplayedPackets: false, group: .domains),
            classificationRevision: 1
        )

        #expect(EndpointStatisticsRowActionPolicy.isEnabled(
            committedState: committed,
            currentState: committed,
            isWaitingForDisplayFilter: false
        ))
        #expect(!EndpointStatisticsRowActionPolicy.isEnabled(
            committedState: committed,
            currentState: changedGroup,
            isWaitingForDisplayFilter: false
        ))
        #expect(!EndpointStatisticsRowActionPolicy.isEnabled(
            committedState: committed,
            currentState: committed,
            isWaitingForDisplayFilter: true
        ))
    }

    @Test func metadataReclassificationDiscardsOldDomainPresentationAndActions() {
        let context = Self.context(usesDisplayedPackets: false)
        let decision = EndpointStatisticsPresentationCommitPolicy.decision(
            requestContext: context,
            currentContext: context,
            requestIngestCursor: Self.cursor(revision: 1, lineage: 7, count: 1),
            currentIngestCursor: Self.cursor(revision: 2, lineage: 7, count: 1),
            requestDisplayedCursor: nil,
            currentDisplayedCursor: nil,
            requestClassificationRevision: 3,
            currentClassificationRevision: 4,
            isWaitingForDisplayFilter: false
        )
        let oldDomainState = EndpointStatisticsActionState(
            context: context,
            classificationRevision: 3
        )
        let newDomainState = EndpointStatisticsActionState(
            context: context,
            classificationRevision: 4
        )

        #expect(decision == .discard)
        #expect(!EndpointStatisticsRowActionPolicy.isEnabled(
            committedState: oldDomainState,
            currentState: newDomainState,
            isWaitingForDisplayFilter: false
        ))
    }

    @Test func largeTablesStopAutomaticRefreshUntilAnExplicitRequest() {
        var policy = EndpointStatisticsAutomaticRefreshPolicy()
        #expect(policy.accepts(.automatic))

        policy.didCommit(
            unfilteredEndpointCount: EndpointStatisticsAutomaticRefreshPolicy.maximumLiveEndpointCount + 1
        )

        for _ in 0..<1_000 {
            #expect(!policy.accepts(.automatic))
        }
        #expect(policy.accepts(.explicit))
    }

    @Test func pendingExplicitIntentOutranksFinalAutomaticDrainCallback() {
        #expect(EndpointStatisticsPresentationIntent.automatic.merging(.explicit) == .explicit)
        #expect(EndpointStatisticsPresentationIntent.explicit.merging(.automatic) == .explicit)
        #expect(EndpointStatisticsPresentationIntent.automatic.merging(nil) == .automatic)
    }

    @Test func displayedRecoveryIntentIsConsumedBeforeALaterUnrelatedOverflow() {
        var state = EndpointStatisticsDisplayedReplacementRecoveryState(
            isPaused: false,
            pendingSourceReplacement: true
        )

        state.replacementWasAccepted()

        #expect(!state.isPaused)
        #expect(!state.shouldResumeAutomatically)

        state.pauseForOverflow()

        #expect(state.isPaused)
        #expect(!state.shouldResumeAutomatically)

        state.pendingSourceReplacement = true
        #expect(state.shouldResumeAutomatically)
    }

    @Test func presenterStopsSearchAndSortWhenCancelled() {
        let rows = (0..<2_000).map { index in
            EndpointStatisticsTablePresentationTests.makeRow(
                key: "endpoint-\(index)",
                domain: "\(index).example",
                bytes: UInt64(index)
            )
        }
        let token = EndpointStatisticsCancellationToken(cancelAfterCheckCount: 2)

        let result = EndpointStatisticsTablePresenter.presentation(
            rows: rows,
            searchText: "example",
            sort: .busiestFirst,
            cancellationToken: token
        )

        #expect(result == nil)
    }

    @Test func classificationRevisionAdvancesForMetadataButNotPureAppends() {
        var pipeline = EndpointStatisticsScopeUpdatePipeline()
        let replacement = EndpointStatisticsIngestUpdate(
            packetRevision: 1,
            packetLineageRevision: 1,
            totalPacketCount: 0,
            kind: .replace([])
        )
        guard case .drain = pipeline.enqueue(replacement) else {
            Issue.record("Expected the replacement to start a drain.")
            return
        }
        _ = pipeline.drainCompleted(result: .consumed)
        #expect(pipeline.latestClassificationRevision == 1)
        #expect(pipeline.consumedClassificationRevision == 1)

        let append = EndpointStatisticsIngestUpdate(
            packetRevision: 2,
            packetLineageRevision: 1,
            totalPacketCount: 0,
            kind: .append([])
        )
        _ = pipeline.enqueue(append)
        #expect(pipeline.latestClassificationRevision == 1)

        let metadata = EndpointStatisticsIngestUpdate(
            packetRevision: 3,
            packetLineageRevision: 1,
            totalPacketCount: 0,
            kind: .metadata([])
        )
        _ = pipeline.enqueue(metadata)
        #expect(pipeline.latestClassificationRevision == 2)
    }
}

private extension EndpointStatisticsPresentationCommitPolicyTests {
    static func context(
        usesDisplayedPackets: Bool,
        group: EndpointStatisticsGroup = .apps
    ) -> EndpointStatisticsPresentationContext {
        EndpointStatisticsPresentationContext(
            usesDisplayedPackets: usesDisplayedPackets,
            sourceIdentity: EndpointStatisticsSourceIdentity(
                backingIdentity: "capture-a",
                packetLineageRevision: 7
            ),
            group: group,
            searchText: "",
            sort: .busiestFirst
        )
    }

    static func cursor(
        revision: UInt64,
        lineage: UInt64,
        count: Int
    ) -> EndpointStatisticsIngestCursor {
        EndpointStatisticsIngestCursor(
            packetRevision: revision,
            packetLineageRevision: lineage,
            totalPacketCount: count
        )
    }
}

private extension EndpointStatisticsTablePresentationTests {
    static func makeRow(
        key: String,
        address: String? = nil,
        port: String? = nil,
        protocolName: String? = "TCP",
        client: String? = nil,
        domain: String? = nil,
        isClientMultiple: Bool = false,
        packets: UInt64 = 1,
        bytes: UInt64 = 0,
        txPackets: UInt64 = 0,
        txBytes: UInt64 = 0,
        rxPackets: UInt64 = 0,
        rxBytes: UInt64 = 0
    ) -> EndpointStatisticsRow {
        EndpointStatisticsRow(
            id: EndpointStatisticsRowID(group: .tcp, key: key),
            address: address,
            port: port,
            protocolName: protocolName,
            client: client,
            domain: domain,
            isClientMultiple: isClientMultiple,
            packets: packets,
            bytes: bytes,
            txPackets: txPackets,
            txBytes: txBytes,
            rxPackets: rxPackets,
            rxBytes: rxBytes,
            unclassifiedPackets: 0,
            unclassifiedBytes: 0
        )
    }
}
