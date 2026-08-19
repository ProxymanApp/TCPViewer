//
//  DecryptedStreamTextFormatterTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 19/8/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct DecryptedStreamTextFormatterTests {
    @Test func rendersReadableUTF8AsText() {
        let text = "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n"

        #expect(DecryptedStreamTextFormatter.string(for: Data(text.utf8)) == text)
    }

    @Test func rendersControlsAndInvalidUTF8AsHexAndASCII() {
        let output = DecryptedStreamTextFormatter.string(for: Data([0x48, 0x00, 0xFF]))
        let deleteOutput = DecryptedStreamTextFormatter.string(for: Data([0x48, 0x7F]))

        #expect(output.contains("00000000"))
        #expect(output.contains("48 00 ff"))
        #expect(output.contains("|H..|"))
        #expect(deleteOutput.contains("48 7f"))
    }
}
