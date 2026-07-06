import Foundation

public enum Logger {
    public enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    private static let lock = NSLock()
    private static nonisolated(unsafe) var _isJSONMode = false

    public static func setJSONMode(_ enabled: Bool) {
        lock.lock()
        _isJSONMode = enabled
        lock.unlock()
    }

    private static var isJSONMode: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isJSONMode
    }

    public static func debug(_ message: String, file: String = #file, function: String = #function) {
        log(.debug, message)
    }

    public static func info(_ message: String) {
        log(.info, message)
    }

    public static func warn(_ message: String) {
        log(.warn, message)
    }

    public static func error(_ message: String) {
        log(.error, message)
    }

    private static func log(_ level: Level, _ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [\(level.rawValue)] \(message)"

        if let data = (line + "\n").data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
