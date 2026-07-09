#if os(Windows)
import WinSDK

enum PlatformTerminalInput {
    static var isInteractiveTerminal: Bool {
        _isatty(_fileno(stdin)) != 0
    }

    static func readSecret(prompt: String) throws -> String {
        try TerminalSecretReader.readSecret(
            prompt: prompt,
            isInteractive: isInteractiveTerminal,
            writePrompt: { prompt in fputs(prompt, stdout); fflush(stdout) },
            writeNewline: { fputs("\n", stdout); fflush(stdout) },
            disableEcho: {
                let handle = GetStdHandle(DWORD(STD_INPUT_HANDLE))
                var originalMode: DWORD = 0
                guard GetConsoleMode(handle, &originalMode) != 0 else {
                    throw TerminalInputError.terminalConfiguration("GetConsoleMode failed with error \(GetLastError())")
                }
                let hiddenMode = originalMode & ~DWORD(ENABLE_ECHO_INPUT)
                guard SetConsoleMode(handle, hiddenMode) != 0 else {
                    throw TerminalInputError.terminalConfiguration("SetConsoleMode failed with error \(GetLastError())")
                }
                return { _ = SetConsoleMode(handle, originalMode) }
            },
            lineReader: { Swift.readLine() }
        )
    }
}
#endif
