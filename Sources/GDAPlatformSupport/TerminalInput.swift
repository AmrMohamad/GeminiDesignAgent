import Foundation

public enum TerminalInputError: Error, LocalizedError, Equatable {
    case interactiveTerminalRequired
    case readFailed
    case terminalConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .interactiveTerminalRequired: "An interactive terminal is required to enter a secret"
        case .readFailed: "No secret was entered"
        case .terminalConfiguration(let details): "Could not configure terminal input: \(details)"
        }
    }
}

public enum TerminalInput {
    public static var isInteractiveTerminal: Bool {
        PlatformTerminalInput.isInteractiveTerminal
    }

    public static func readSecret(prompt: String) throws -> String {
        try PlatformTerminalInput.readSecret(prompt: prompt)
    }
}

enum TerminalSecretReader {
    static func readSecret(
        prompt: String,
        isInteractive: Bool,
        writePrompt: (String) -> Void,
        writeNewline: () -> Void,
        disableEcho: () throws -> (() -> Void),
        lineReader: () -> String?
    ) throws -> String {
        guard isInteractive else { throw TerminalInputError.interactiveTerminalRequired }
        writePrompt(prompt)
        let restoreEcho = try disableEcho()
        defer {
            restoreEcho()
            writeNewline()
        }
        guard let value = lineReader() else { throw TerminalInputError.readFailed }
        return value
    }
}
