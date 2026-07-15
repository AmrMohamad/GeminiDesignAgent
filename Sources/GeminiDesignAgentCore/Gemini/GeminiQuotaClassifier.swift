import Foundation

public enum GeminiQuotaClassification: Sendable, Equatable {
    case dailyProjectQuota(resetAt: Date?)
    case modelScopedQuota(retryAfter: Duration?)
    case temporaryRateLimit(retryAfter: Duration?)
    case spendLimit(retryAfter: Duration?)
    case unknownRateLimit
}

/// Pure classification for 429 envelopes. Per-project quota is surfaced to the
/// user; only an explicit model-scoped signal can unlock same-account model
/// fallback.
public struct GeminiQuotaClassifier: Sendable {
    public init() {}

    public func classify(
        httpStatus: Int,
        canonicalStatus: String?,
        message: String?,
        details: String,
        retryAfter: Duration? = nil
    ) -> GeminiQuotaClassification {
        guard httpStatus == 429,
              normalize(canonicalStatus).contains("resourceexhausted") || normalize(canonicalStatus).contains("quotaexceeded") else {
            return .unknownRateLimit
        }

        let signal = normalize([message, details].compactMap { $0 }.joined(separator: " "))
        let daily = ["requestsperday", "requestperday", "perdayperproject", "dailyquota", "dailyrequest"]
        // A fallback is permitted only when the provider explicitly identifies
        // the limit as belonging to a model. Generic 429s are intentionally not
        // treated as model failures.
        let modelScoped = ["permodelperday", "modelscopedquota", "modelquota", "modelrequestsdaily"]
        let temporary = ["requestsperminute", "tokensperminute", "rpm", "tpm", "temporarycapacity", "rollingwindow"]
        let spend = ["spendlimit", "billinglimit", "budgetlimit"]

        if modelScoped.contains(where: signal.contains), !temporary.contains(where: signal.contains), !spend.contains(where: signal.contains) {
            return .modelScopedQuota(retryAfter: retryAfter)
        }
        if daily.contains(where: signal.contains), !temporary.contains(where: signal.contains), !spend.contains(where: signal.contains) {
            return .dailyProjectQuota(resetAt: nil)
        }
        if spend.contains(where: signal.contains) {
            return .spendLimit(retryAfter: retryAfter)
        }
        if temporary.contains(where: signal.contains) {
            return .temporaryRateLimit(retryAfter: retryAfter)
        }
        return .unknownRateLimit
    }

    private func normalize(_ value: String?) -> String {
        (value ?? "").unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined().lowercased()
    }
}
