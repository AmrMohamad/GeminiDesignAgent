#if os(Linux)
import Glibc

enum PlatformTerminalInput {
    static var isInteractiveTerminal: Bool {
        isatty(STDIN_FILENO) == 1
    }

    static func readSecret(prompt: String) throws -> String {
        try TerminalSecretReader.readSecret(
            prompt: prompt,
            isInteractive: isInteractiveTerminal,
            writePrompt: { prompt in fputs(prompt, stdout); fflush(stdout) },
            writeNewline: { fputs("\n", stdout); fflush(stdout) },
            disableEcho: {
                var original = termios()
                guard tcgetattr(STDIN_FILENO, &original) == 0 else {
                    throw TerminalInputError.terminalConfiguration(String(cString: strerror(errno)))
                }
                var hidden = original
                hidden.c_lflag &= ~tcflag_t(ECHO)
                guard tcsetattr(STDIN_FILENO, TCSANOW, &hidden) == 0 else {
                    throw TerminalInputError.terminalConfiguration(String(cString: strerror(errno)))
                }
                return {
                    var restore = original
                    _ = tcsetattr(STDIN_FILENO, TCSANOW, &restore)
                }
            },
            lineReader: { Swift.readLine() }
        )
    }
}
#endif
