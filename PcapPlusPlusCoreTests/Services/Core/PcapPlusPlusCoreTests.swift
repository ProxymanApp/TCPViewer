//
//  PcapPlusPlusCoreTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/4/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct PcapPlusPlusCoreTests {

    @Test func nativeLiveSessionCanStopBeforeStart() async throws {
        let core = NativeTCPViewerCore()
        guard let captureInterface = try await core.listInterfaces().first(where: \.isSelectable) else {
            return
        }

        let session = try await core.makeLiveCaptureSession(
            interfaceID: captureInterface.id,
            options: CaptureOptions.defaults(for: captureInterface)
        )

        try await session.stop()
    }
}
