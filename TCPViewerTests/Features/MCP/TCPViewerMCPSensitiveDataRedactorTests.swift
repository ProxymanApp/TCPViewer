//
//  TCPViewerMCPSensitiveDataRedactorTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Testing
@testable import TCPViewer

struct TCPViewerMCPSensitiveDataRedactorTests {
    private let redactor = TCPViewerMCPSensitiveDataRedactor()

    @Test func redactsCredentialFormatsWithoutRemovingSafeValues() {
        let input = """
        Authorization: Bearer abc.def.ghi
        Cookie: session=secret
        https://user:password@example.com/path?api_key=123&safe=yes
        {"password":"hunter2","access_token":"token-value","name":"Taylor"}
        Basic dXNlcjpwYXNz
        github_pat_abcdefghijklmnopqrstuvwxyz123456
        -----BEGIN PRIVATE KEY-----
        hidden
        -----END PRIVATE KEY-----
        """

        let output = redactor.redact(input)

        #expect(!output.contains("abc.def.ghi"))
        #expect(!output.contains("session=secret"))
        #expect(!output.contains(":password@"))
        #expect(!output.contains("api_key=123"))
        #expect(output.contains("safe=yes"))
        #expect(!output.contains("hunter2"))
        #expect(!output.contains("token-value"))
        #expect(output.contains("Taylor"))
        #expect(!output.contains("dXNlcjpwYXNz"))
        #expect(!output.contains("github_pat_abcdefghijklmnopqrstuvwxyz123456"))
        #expect(!output.contains("hidden"))
    }

    @Test func redactsStructuredKeysAndNameValueEntriesRecursively() {
        let value = TCPViewerMCPValue.object([
            "safe": .string("visible"),
            "password": .string("secret"),
            "headers": .array([
                .object(["name": .string("Authorization"), "value": .string("Bearer hidden")]),
                .object(["name": .string("Accept"), "value": .string("application/json")]),
            ]),
            "nested": .object(["client_secret": .string("private")]),
            "api_secret_value": .string("another-private-value"),
            "sessionToken": .string("session-private-value"),
        ])

        let redacted = redactor.redact(value).objectValue
        let headers = redacted?["headers"]?.arrayValue

        #expect(redacted?["safe"] == .string("visible"))
        #expect(redacted?["password"] == .string(TCPViewerMCPSensitiveDataRedactor.placeholder))
        #expect(headers?[0].objectValue?["value"] == .string(TCPViewerMCPSensitiveDataRedactor.placeholder))
        #expect(headers?[1].objectValue?["value"] == .string("application/json"))
        #expect(redacted?["nested"]?.objectValue?["client_secret"] == .string(TCPViewerMCPSensitiveDataRedactor.placeholder))
        #expect(redacted?["api_secret_value"] == .string(TCPViewerMCPSensitiveDataRedactor.placeholder))
        #expect(redacted?["sessionToken"] == .string(TCPViewerMCPSensitiveDataRedactor.placeholder))
    }

    @Test func sensitiveNameMatchingHandlesCommonSpellingVariantsAndRejectsSafeNames() {
        for name in ["x-api-key", "API_KEY", "apiSecretValue", "clientSecret", "refresh_token", "sessionToken", "user-password", "Private Key"] {
            #expect(redactor.isSensitiveName(name))
        }
        for name in ["content-length", "packet_number", "domain", "monkey", "tokenization"] {
            #expect(!redactor.isSensitiveName(name))
        }
    }
}
