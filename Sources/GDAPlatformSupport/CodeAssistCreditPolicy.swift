import GeminiDesignAgentCore

public enum CodeAssistCreditPolicy {
    public static let minimumBalance = 50
    public static let eligibleModels: Set<String> = [
        "gemini-3-pro-preview",
        "gemini-3.1-pro-preview",
        "gemini-3-flash-preview"
    ]

    public static func enabledCreditTypes(
        policy: CreditPolicy,
        model: String,
        balance: Int?,
        consentGranted: Bool
    ) -> [String]? {
        guard eligibleModels.contains(model),
              let balance,
              balance >= minimumBalance else {
            return nil
        }
        switch policy {
        case .never: return nil
        case .ask: return consentGranted ? [CodeAssist.CreditType.googleOneAI.rawValue] : nil
        case .always: return [CodeAssist.CreditType.googleOneAI.rawValue]
        }
    }
}
