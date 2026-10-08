//
//  TLSDecryptionViewModelTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TLSDecryptionViewModelTests {
    @Test func rowsShowNameFolderAndSessionCount() {
        let viewModel = TLSDecryptionViewModel()
        let home = FileManager.default.homeDirectoryForCurrentUser

        viewModel.render(snapshot: TLSDecryptionSnapshot(
            isEnabled: true,
            files: [
                file(home.appendingPathComponent("Desktop/tlskeylog.txt"), .ready(sessionCount: 39, keyCount: 195, skippedLineCount: 0)),
                file(URL(fileURLWithPath: "/tmp/one.keys"), .ready(sessionCount: 1, keyCount: 1, skippedLineCount: 2), isEnabled: false),
                file(URL(fileURLWithPath: "/tmp/legacy.keys"), .ready(sessionCount: 0, keyCount: 3, skippedLineCount: 1)),
            ],
            activityMessage: "Updated 214 packets in a.pcapng."
        ))

        #expect(viewModel.isEnabled)
        #expect(viewModel.footerText == "Updated 214 packets in a.pcapng.")
        #expect(viewModel.rows.map(\.title) == ["tlskeylog.txt", "one.keys", "legacy.keys"])
        #expect(viewModel.rows.map(\.detail) == ["39 sessions", "1 session", "3 keys"])
        #expect(viewModel.rows.map(\.subtitle) == ["~/Desktop", "/tmp · 2 lines skipped", "/tmp · 1 line skipped"])
        #expect(viewModel.rows.map(\.isChecked) == [true, false, true])
        #expect(viewModel.rows.allSatisfy { !$0.hasProblem })
    }

    @Test func unusableFilesExplainWhyInsteadOfShowingACount() {
        let viewModel = TLSDecryptionViewModel()

        viewModel.render(snapshot: TLSDecryptionSnapshot(
            isEnabled: false,
            files: [
                file(URL(fileURLWithPath: "/tmp/a"), .missing),
                file(URL(fileURLWithPath: "/tmp/b"), .noKeys),
                file(URL(fileURLWithPath: "/tmp/c"), .unreadable),
                file(URL(fileURLWithPath: "/tmp/d"), .tooLarge),
                file(URL(fileURLWithPath: "/tmp/e"), .reading),
            ],
            activityMessage: ""
        ))

        #expect(!viewModel.isEnabled)
        #expect(viewModel.rows.map(\.subtitle) == [
            "/tmp · File not found",
            "/tmp · No TLS keys in this file",
            "/tmp · File cannot be read",
            "/tmp · File is too large for a key log",
            "/tmp",
        ])
        #expect(viewModel.rows.map(\.detail) == ["", "", "", "", "Reading…"])
        #expect(viewModel.rows.map(\.hasProblem) == [true, true, true, true, false])
    }

    private func file(_ url: URL, _ status: TLSKeyLogFile.Status, isEnabled: Bool = true) -> TLSKeyLogFile {
        TLSKeyLogFile(url: url, isEnabled: isEnabled, status: status)
    }
}
