import Foundation

/// Release and wire-contract versions shared by the core library and CLI.
public enum GDAContract {
    public static let productVersion = "0.1.0"
    public static let skillProtocolVersion = "1"
    public static let geminiAPIVersion = "v1"
    public static let promptSchemaVersion = "1.0"
    public static let analysisSchemaVersion = "1.0"
    public static let databaseSchemaVersion = 2
    public static let handoffSchemaVersion = "gda.design_handoff.v1"
    public static let defaultModel = "gemini-3.5-flash"

    public static let version = GDAVersionContract(
        version: productVersion,
        skillProtocolVersion: skillProtocolVersion,
        geminiAPIVersion: geminiAPIVersion,
        promptSchemaVersion: promptSchemaVersion,
        analysisSchemaVersion: analysisSchemaVersion,
        databaseSchemaVersion: databaseSchemaVersion,
        handoffSchemaVersion: handoffSchemaVersion
    )
}

public struct GDAVersionContract: Codable, Equatable, Sendable {
    public var version: String
    public var skillProtocolVersion: String
    public var geminiAPIVersion: String
    public var promptSchemaVersion: String
    public var analysisSchemaVersion: String
    public var databaseSchemaVersion: Int
    public var handoffSchemaVersion: String

    enum CodingKeys: String, CodingKey {
        case version
        case skillProtocolVersion = "skill_protocol_version"
        case geminiAPIVersion = "gemini_api_version"
        case promptSchemaVersion = "prompt_schema_version"
        case analysisSchemaVersion = "analysis_schema_version"
        case databaseSchemaVersion = "database_schema_version"
        case handoffSchemaVersion = "handoff_schema_version"
    }
}
