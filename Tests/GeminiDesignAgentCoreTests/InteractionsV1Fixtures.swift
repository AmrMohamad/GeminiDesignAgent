import Foundation

// Source: https://ai.google.dev/static/api/interactions-v1.openapi.json
// Retrieved: 2026-07-09. These examples preserve the documented REST fields,
// not SDK-only conveniences such as output_text.
enum InteractionsV1Fixtures {
    static let completed = #"""
    {
      "id": "v1_fixture",
      "model": "gemini-2.5-flash",
      "status": "completed",
      "steps": [
        {
          "type": "model_output",
          "content": [
            { "type": "text", "text": "{\"ok\":" },
            { "type": "text", "text": "true}" }
          ]
        }
      ],
      "usage": {
        "total_input_tokens": 7,
        "total_output_tokens": 20,
        "total_tokens": 27
      }
    }
    """#

    static let rateLimitedError = #"""
    { "error": { "code": "rate_limited", "message": "Rate limit exceeded" } }
    """#

    static let quotaExhaustedError = #"""
    {
      "error": {
        "code": 429,
        "status": "RESOURCE_EXHAUSTED",
        "message": "You exceeded your current quota.",
        "details": [{
          "@type": "type.googleapis.com/google.rpc.QuotaFailure",
          "violations": [{
            "quotaMetric": "generativelanguage.googleapis.com/generate_content_requests",
            "quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier"
          }]
        }]
      }
    }
    """#

    static let requestsPerMinuteError = quotaError(quotaID: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier")
    static let tokensPerMinuteError = quotaError(quotaID: "GenerateContentInputTokensPerModelPerMinute-FreeTier")
    static let rollingSpendError = quotaError(quotaID: "RollingSpendLimitPerProject")
    static let unknownResourceExhaustedError = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"You exceeded your current quota."}}"#
    static let retryInfoError = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Temporarily unavailable","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"12s"}]}}"#

    private static func quotaError(quotaID: String) -> String {
        #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"You exceeded your current quota.","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaMetric":"generativelanguage.googleapis.com/generate_content_requests","quotaId":"\#(quotaID)"}]}]}}"#
    }

    static let safetyError = #"""
    { "error": { "code": "CONTENT_BLOCKED", "message": "Blocked by safety policy" } }
    """#
}
