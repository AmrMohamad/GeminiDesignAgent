import XCTest
@testable import GDAPlatformSupport

final class PlatformSupportTests: XCTestCase {
    func testTerminalInputErrorsAreActionable() {
        XCTAssertEqual(TerminalInputError.interactiveTerminalRequired.errorDescription, "An interactive terminal is required to enter a secret")
    }

    func testNonInteractiveTerminalNeverPromptsOrReadsSecret() {
        var prompted = false
        var configuredEcho = false
        XCTAssertThrowsError(
            try TerminalSecretReader.readSecret(
                prompt: "API key: ",
                isInteractive: false,
                writePrompt: { _ in prompted = true },
                writeNewline: {},
                disableEcho: { configuredEcho = true; return {} },
                lineReader: { "piped-secret" }
            )
        ) { error in
            XCTAssertEqual(error as? TerminalInputError, .interactiveTerminalRequired)
        }
        XCTAssertFalse(prompted)
        XCTAssertFalse(configuredEcho)
    }

    func testSecretReaderRestoresEchoAndPrintsNewlineAfterSuccess() throws {
        let recorder = TerminalRecorder()
        let value = try TerminalSecretReader.readSecret(
            prompt: "API key: ",
            isInteractive: true,
            writePrompt: { recorder.prompt = $0 },
            writeNewline: { recorder.didPrintNewline = true },
            disableEcho: {
                recorder.didDisableEcho = true
                return { recorder.didRestoreEcho = true }
            },
            lineReader: { "secret" }
        )

        XCTAssertEqual(value, "secret")
        XCTAssertEqual(recorder.prompt, "API key: ")
        XCTAssertTrue(recorder.didDisableEcho)
        XCTAssertTrue(recorder.didRestoreEcho)
        XCTAssertTrue(recorder.didPrintNewline)
    }

    func testSecretReaderRestoresEchoAndPrintsNewlineAfterReadFailure() {
        let recorder = TerminalRecorder()
        XCTAssertThrowsError(
            try TerminalSecretReader.readSecret(
                prompt: "API key: ",
                isInteractive: true,
                writePrompt: { recorder.prompt = $0 },
                writeNewline: { recorder.didPrintNewline = true },
                disableEcho: {
                    recorder.didDisableEcho = true
                    return { recorder.didRestoreEcho = true }
                },
                lineReader: { nil }
            )
        ) { error in
            XCTAssertEqual(error as? TerminalInputError, .readFailed)
        }
        XCTAssertTrue(recorder.didDisableEcho)
        XCTAssertTrue(recorder.didRestoreEcho)
        XCTAssertTrue(recorder.didPrintNewline)
    }

    func testAPIKeyValidationRejectsWhitespaceAndPreservesTrimmedKey() throws {
        let store = TestAPIKeyStore()
        XCTAssertEqual(try store.validated("  valid-key  "), "valid-key")
        XCTAssertThrowsError(try store.validated(" \n ")) { error in
            XCTAssertEqual(error as? APIKeyStoreError, .emptyKey)
        }
    }

    #if os(Linux)
    func testLinuxSecretToolRunnerTimesOut() {
        let runner = LinuxSecretToolRunner(timeoutSeconds: 0, command: "sh")
        XCTAssertThrowsError(try runner.run(arguments: ["-c", "sleep 2"])) { error in
            guard case APIKeyStoreError.unavailable = error else {
                return XCTFail("Expected persistence-unavailable error, got \(error)")
            }
        }
    }
    #endif
}

private final class TerminalRecorder {
    var prompt: String?
    var didDisableEcho = false
    var didRestoreEcho = false
    var didPrintNewline = false
}

private struct TestAPIKeyStore: APIKeyStore {
    let persistenceDescription = "test"

    func save(_ key: String) throws {}
    func load() throws -> String? { nil }
    func delete() throws {}
}
