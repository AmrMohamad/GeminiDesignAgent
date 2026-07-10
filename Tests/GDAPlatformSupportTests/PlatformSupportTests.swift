import XCTest
@testable import GDAPlatformSupport
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

final class PlatformSupportTests: XCTestCase {
    func testCredentialSlotsHaveDistinctPlatformIdentifiers() {
        XCTAssertEqual(CredentialSlotIdentifier.account(for: "primary"), "gemini-api-key")
        XCTAssertNotEqual(CredentialSlotIdentifier.account(for: "pool-registry"), CredentialSlotIdentifier.account(for: "fallback-1"))
        XCTAssertNotEqual(CredentialSlotIdentifier.account(for: "fallback-1"), CredentialSlotIdentifier.account(for: "fallback-2"))
        XCTAssertNotEqual(CredentialSlotIdentifier.windowsTarget(for: "pool-registry"), CredentialSlotIdentifier.windowsTarget(for: "fallback-1"))
    }

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

    func testSecretReaderPreservesReadFailureWhenNewlineWriteAlsoFails() {
        let recorder = TerminalRecorder()
        XCTAssertThrowsError(
            try TerminalSecretReader.readSecret(
                prompt: "API key: ",
                isInteractive: true,
                writePrompt: { recorder.prompt = $0 },
                writeNewline: {
                    recorder.didPrintNewline = true
                    throw TerminalInputError.terminalConfiguration("newline failed")
                },
                disableEcho: {
                    recorder.didDisableEcho = true
                    return { recorder.didRestoreEcho = true }
                },
                lineReader: { nil }
            )
        ) { error in
            XCTAssertEqual(error as? TerminalInputError, .readFailed)
        }
        XCTAssertTrue(recorder.didRestoreEcho)
        XCTAssertTrue(recorder.didPrintNewline)
    }

    func testSecretReaderSurfacesNewlineWriteFailureAfterSuccessfulRead() {
        let recorder = TerminalRecorder()
        let expected = TerminalInputError.terminalConfiguration("newline failed")
        XCTAssertThrowsError(
            try TerminalSecretReader.readSecret(
                prompt: "API key: ",
                isInteractive: true,
                writePrompt: { recorder.prompt = $0 },
                writeNewline: { throw expected },
                disableEcho: {
                    recorder.didDisableEcho = true
                    return { recorder.didRestoreEcho = true }
                },
                lineReader: { "secret" }
            )
        ) { error in
            XCTAssertEqual(error as? TerminalInputError, expected)
        }
        XCTAssertTrue(recorder.didRestoreEcho)
    }

    func testSecretReaderDoesNotChangeEchoAfterPromptWriteFailure() {
        let recorder = TerminalRecorder()
        let expected = TerminalInputError.terminalConfiguration("prompt failed")
        XCTAssertThrowsError(
            try TerminalSecretReader.readSecret(
                prompt: "API key: ",
                isInteractive: true,
                writePrompt: { _ in throw expected },
                writeNewline: { recorder.didPrintNewline = true },
                disableEcho: {
                    recorder.didDisableEcho = true
                    return { recorder.didRestoreEcho = true }
                },
                lineReader: { "secret" }
            )
        ) { error in
            XCTAssertEqual(error as? TerminalInputError, expected)
        }
        XCTAssertFalse(recorder.didDisableEcho)
        XCTAssertFalse(recorder.didRestoreEcho)
        XCTAssertFalse(recorder.didPrintNewline)
    }

    func testAPIKeyValidationRejectsWhitespaceAndPreservesTrimmedKey() throws {
        let store = TestAPIKeyStore()
        XCTAssertEqual(try store.validated("  valid-key  "), "valid-key")
        XCTAssertThrowsError(try store.validated(" \n ")) { error in
            XCTAssertEqual(error as? APIKeyStoreError, .emptyKey)
        }
    }

    #if os(Linux)
    func testLinuxTerminalWriterPreservesUTF8BytesThroughPipe() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Glibc.pipe(&descriptors), 0)
        var readDescriptor = descriptors[0]
        var writeDescriptor = descriptors[1]
        defer {
            if readDescriptor >= 0 { _ = Glibc.close(readDescriptor) }
            if writeDescriptor >= 0 { _ = Glibc.close(writeDescriptor) }
        }

        let expected = "API key 🔑: "
        try PlatformTerminalInput.writeUTF8(expected, to: writeDescriptor)
        XCTAssertEqual(Glibc.close(writeDescriptor), 0)
        writeDescriptor = -1

        var received = [UInt8](repeating: 0, count: expected.utf8.count)
        var totalRead = 0
        while totalRead < received.count {
            let readCount = received.withUnsafeMutableBytes { buffer in
                Glibc.read(
                    readDescriptor,
                    buffer.baseAddress?.advanced(by: totalRead),
                    buffer.count - totalRead
                )
            }
            if readCount > 0 {
                totalRead += readCount
            } else if readCount == -1, errno == EINTR {
                continue
            } else if readCount == 0 {
                break
            } else {
                return XCTFail("Pipe read failed: \(String(cString: strerror(errno)))")
            }
        }
        XCTAssertEqual(totalRead, expected.utf8.count)
        XCTAssertEqual(received, Array(expected.utf8))
        XCTAssertEqual(Glibc.close(readDescriptor), 0)
        readDescriptor = -1
    }

    func testLinuxTerminalWriterRejectsInvalidDescriptor() {
        XCTAssertThrowsError(try PlatformTerminalInput.writeUTF8("prompt", to: -1)) { error in
            guard case TerminalInputError.terminalConfiguration(let details) = error else {
                return XCTFail("Expected terminal-configuration error, got \(error)")
            }
            XCTAssertTrue(details.contains("Could not write terminal output"))
        }
    }

    func testLinuxSecretToolRunnerTimesOut() {
        let runner = LinuxSecretToolRunner(timeoutSeconds: 0, command: "sh")
        XCTAssertThrowsError(try runner.run(arguments: ["-c", "sleep 2"])) { error in
            guard case APIKeyStoreError.unavailable = error else {
                return XCTFail("Expected persistence-unavailable error, got \(error)")
            }
        }
    }
    #elseif os(Windows)
    func testWindowsTerminalWriterAcceptsEmptyUTF8Output() throws {
        try PlatformTerminalInput.writeUTF8("", to: STD_OUTPUT_HANDLE)
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

    init(slot: String = "primary") {}

    func save(_ key: String) throws {}
    func load() throws -> String? { nil }
    func delete() throws {}
}
