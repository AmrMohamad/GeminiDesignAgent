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
            writePrompt: { try writeUTF8($0, to: STDOUT_FILENO) },
            writeNewline: { try writeUTF8("\n", to: STDOUT_FILENO) },
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

    static func writeUTF8(_ value: String, to fileDescriptor: Int32) throws {
        let bytes = Array(value.utf8)
        try bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }

            var offset = 0
            while offset < buffer.count {
                let written = Glibc.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    let details = written == 0
                        ? "write made no progress"
                        : String(cString: strerror(errno))
                    throw TerminalInputError.terminalConfiguration(
                        "Could not write terminal output: \(details)"
                    )
                }
            }
        }
    }
}
#endif
