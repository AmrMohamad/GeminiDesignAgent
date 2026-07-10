import Foundation

/// Stable, non-secret identifiers used by the platform credential stores.
/// Keeping this mapping pure makes collisions testable without touching a real keychain.
public enum CredentialSlotIdentifier {
    public static func account(for slot: String) -> String {
        slot == "primary" ? "gemini-api-key" : "gemini-api-key.\(slot)"
    }

    public static func windowsTarget(for slot: String) -> String {
        slot == "primary"
            ? "GeminiDesignAgent.GeminiAPIKey"
            : "GeminiDesignAgent.GeminiAPIKey.\(slot)"
    }
}
