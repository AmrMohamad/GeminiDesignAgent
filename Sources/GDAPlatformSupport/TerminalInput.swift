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
        writePrompt: (String) throws -> Void,
        writeNewline: () throws -> Void,
        disableEcho: () throws -> (() -> Void),
        lineReader: () -> String?
    ) throws -> String {
        guard isInteractive else { throw TerminalInputError.interactiveTerminalRequired }
        try writePrompt(prompt)
        let restoreEcho = try disableEcho()
        let value = lineReader()
        restoreEcho()

        guard let value else {
            // Preserve the primary read failure if the cosmetic newline also fails.
            try? writeNewline()
            throw TerminalInputError.readFailed
        }
        try writeNewline()
        return value
    }
}
