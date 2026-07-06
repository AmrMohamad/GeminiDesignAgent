import Foundation

public struct Clock: Sendable {
    public var now: @Sendable () -> Date

    public init(now: @Sendable @escaping () -> Date = { Date() }) {
        self.now = now
    }

    public static var system: Clock { Clock() }
}
