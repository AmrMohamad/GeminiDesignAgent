#if os(Linux)
import Foundation
import Glibc
import Dispatch

struct LinuxSecretToolRunner {
    let timeoutSeconds: Int
    let command: String

    init(timeoutSeconds: Int = 10, command: String = "secret-tool") {
        self.timeoutSeconds = timeoutSeconds
        self.command = command
    }

    func run(arguments: [String], stdin: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input

        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            throw APIKeyStoreError.unavailable("Linux Secret Service requires `secret-tool` on PATH. Use --api-key or GEMINI_API_KEY as the guaranteed fallback.")
        }

        if let stdin, let input, let data = stdin.data(using: .utf8) {
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.closeFile()
        }

        if completed.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + .seconds(1)) == .timedOut, process.processIdentifier > 0 {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + .seconds(1))
            }
            throw APIKeyStoreError.unavailable("Linux Secret Service did not respond within \(timeoutSeconds) seconds. Unlock the keyring or use --api-key or GEMINI_API_KEY as the fallback.")
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(data: outputData, encoding: .utf8) ?? ""
        let errorText = String(data: errorData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            if errorText.contains("No such file") || errorText.contains("not found") {
                throw APIKeyStoreError.unavailable("Linux Secret Service requires `secret-tool` on PATH. Use --api-key or GEMINI_API_KEY as the guaranteed fallback.")
            }
            throw APIKeyStoreError.commandFailed(errorText.isEmpty ? "secret-tool failed with status \(process.terminationStatus)" : errorText)
        }
        return outputText
    }
}

public struct PlatformAPIKeyStore: APIKeyStore {
    public let persistenceDescription = "Linux Secret Service"
    private let service = "com.geminidesignagent.gda"
    private let account: String
    private let runner: LinuxSecretToolRunner

    public init(slot: String = "primary") {
        account = slot == "primary" ? "gemini-api-key" : "gemini-api-key.(slot)"
        runner = LinuxSecretToolRunner()
    }

    public func save(_ key: String) throws {
        let trimmed = try validated(key)
        _ = try runner.run(arguments: ["store", "--label=Gemini Design Agent API key", "service", service, "account", account], stdin: trimmed)
    }

    public func load() throws -> String? {
        do {
            let output = try runner.run(arguments: ["lookup", "service", service, "account", account])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch APIKeyStoreError.commandFailed {
            return nil
        }
    }

    public func delete() throws {
        do {
            _ = try runner.run(arguments: ["clear", "service", service, "account", account])
        } catch APIKeyStoreError.commandFailed {
            return
        }
    }
}
#endif
