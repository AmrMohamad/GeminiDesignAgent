import Foundation

public struct RunRecord: Codable, Sendable {
    public var id: String
    public var projectId: String
    public var sessionId: String
    public var screenName: String?
    public var imagePath: String
    public var model: String
    public var request: String
    public var status: String
    public var startedAt: Date
    public var completedAt: Date?
    public var error: String?
}
