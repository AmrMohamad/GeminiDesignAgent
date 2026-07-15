import Foundation

public enum CodeAssistModelResolver {
    public static let modelAliases: [String: String] = [
        "auto": "gemini-2.5-pro",
        "pro": "gemini-2.5-pro",
        "flash": "gemini-3.5-flash",
        "flash-lite": "gemini-2.5-flash"
    ]

    public static let codeAssistModelMappings: [String: String] = [
        "gemini-3.5-flash": "gemini-3-flash"
    ]

    public static func normalize(_ model: String) -> String {
        if model.hasPrefix("models/") {
            return String(model.dropFirst("models/".count))
        }
        return model
    }

    public static func resolveAlias(_ model: String) -> String {
        modelAliases[model] ?? model
    }

    public static func mapModelName(_ model: String) -> String {
        codeAssistModelMappings[model] ?? model
    }

    public static func resolve(_ model: String) -> String {
        let normalized = normalize(model)
        let aliased = resolveAlias(normalized)
        return mapModelName(aliased)
    }
}