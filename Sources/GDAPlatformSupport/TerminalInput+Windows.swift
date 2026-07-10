#if os(Windows)
import WinSDK

enum PlatformTerminalInput {
    static var isInteractiveTerminal: Bool {
        guard let handle = standardHandle(STD_INPUT_HANDLE) else { return false }
        var mode: DWORD = 0
        return GetConsoleMode(handle, &mode)
    }

    static func readSecret(prompt: String) throws -> String {
        try TerminalSecretReader.readSecret(
            prompt: prompt,
            isInteractive: isInteractiveTerminal,
            writePrompt: { try writeUTF8($0, to: STD_OUTPUT_HANDLE) },
            writeNewline: { try writeUTF8("\n", to: STD_OUTPUT_HANDLE) },
            disableEcho: {
                guard let handle = standardHandle(STD_INPUT_HANDLE) else {
                    throw TerminalInputError.terminalConfiguration(
                        "GetStdHandle failed with error \(GetLastError())"
                    )
                }
                var originalMode: DWORD = 0
                guard GetConsoleMode(handle, &originalMode) else {
                    throw TerminalInputError.terminalConfiguration("GetConsoleMode failed with error \(GetLastError())")
                }
                let hiddenMode = originalMode & ~DWORD(ENABLE_ECHO_INPUT)
                guard SetConsoleMode(handle, hiddenMode) else {
                    throw TerminalInputError.terminalConfiguration("SetConsoleMode failed with error \(GetLastError())")
                }
                return { _ = SetConsoleMode(handle, originalMode) }
            },
            lineReader: { Swift.readLine() }
        )
    }

    static func writeUTF8(_ value: String, to standardHandle: DWORD) throws {
        guard let handle = self.standardHandle(standardHandle) else {
            throw TerminalInputError.terminalConfiguration(
                "GetStdHandle failed with error \(GetLastError())"
            )
        }

        try value.utf8CString.withUnsafeBufferPointer { buffer in
            let byteCount = buffer.count - 1
            var offset = 0
            while offset < byteCount {
                var written: DWORD = 0
                guard WriteFile(
                    handle,
                    UnsafeRawPointer(buffer.baseAddress! + offset),
                    DWORD(byteCount - offset),
                    &written,
                    nil
                ) else {
                    throw TerminalInputError.terminalConfiguration(
                        "WriteFile failed with error \(GetLastError())"
                    )
                }
                guard written > 0 else {
                    throw TerminalInputError.terminalConfiguration(
                        "Could not write terminal output: WriteFile made no progress"
                    )
                }
                offset += Int(written)
            }
        }
    }

    private static func standardHandle(_ identifier: DWORD) -> HANDLE? {
        guard let handle = GetStdHandle(identifier),
              handle != INVALID_HANDLE_VALUE else {
            return nil
        }
        return handle
    }
}
#endif
