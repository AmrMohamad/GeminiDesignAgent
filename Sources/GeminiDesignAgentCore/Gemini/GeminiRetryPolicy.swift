import Foundation

struct GeminiRetryPolicy: Sendable {
    let maxRetries: Int
    let maxDelay: Duration
    let randomUnit: @Sendable () -> Double

    init(maxRetries: Int = 5, maxDelay: Duration = .seconds(60), randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.maxRetries = maxRetries
        self.maxDelay = maxDelay
        self.randomUnit = randomUnit
    }

    func calculatedDelay(attempt: Int) -> Duration {
        let maximumSeconds = max(1, Int(maxDelay.components.seconds))
        let exponentialSeconds = min(maximumSeconds, 1 << min(max(0, attempt), 5))
        let random = min(1, max(0, randomUnit()))
        return .milliseconds(Int64((Double(exponentialSeconds) * (0.5 + (random * 0.5)) * 1_000).rounded()))
    }
}
