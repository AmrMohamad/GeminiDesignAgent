import Foundation

public enum OAuthError: Error, LocalizedError, Sendable {
    case invalidClientConfiguration(String)
    case interactiveRequired
    case callbackTimedOut
    case callbackRejected
    case authorizationDenied(String)
    case tokenExchangeFailed(String)
    case reauthenticationRequired
    case profileNotFound
    case credentialStoreUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidClientConfiguration(let message): return "Invalid OAuth client configuration: \(message)"
        case .interactiveRequired: return "Google OAuth sign-in requires an interactive terminal"
        case .callbackTimedOut: return "Google OAuth sign-in timed out"
        case .callbackRejected: return "Google OAuth callback was rejected"
        case .authorizationDenied(let message): return "Google OAuth authorization was denied: \(message)"
        case .tokenExchangeFailed(let message): return "Google OAuth token exchange failed: \(message)"
        case .reauthenticationRequired: return "Google OAuth authorization expired; sign in again"
        case .profileNotFound: return "Google OAuth profile was not found"
        case .credentialStoreUnavailable(let message): return "Secure credential storage is unavailable: \(message)"
        }
    }
}

public struct OAuthClientConfiguration: Codable, Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String
    public let projectID: String

    public init(clientID: String, clientSecret: String, projectID: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.projectID = projectID
    }

    public static func load(from url: URL) throws -> OAuthClientConfiguration {
        struct Document: Decodable {
            struct Installed: Decodable {
                let clientID: String
                let clientSecret: String
                let projectID: String
                let authURI: String?
                let tokenURI: String?

                enum CodingKeys: String, CodingKey {
                    case clientID = "client_id"
                    case clientSecret = "client_secret"
                    case projectID = "project_id"
                    case authURI = "auth_uri"
                    case tokenURI = "token_uri"
                }
            }
            let installed: Installed?
        }

        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard let installed = document.installed else {
            throw OAuthError.invalidClientConfiguration("Only desktop (installed) OAuth client JSON is accepted")
        }
        guard installed.clientID.range(of: "^[0-9]+-[A-Za-z0-9_-]+\\.apps\\.googleusercontent\\.com$", options: .regularExpression) != nil,
              !installed.clientSecret.isEmpty else {
            throw OAuthError.invalidClientConfiguration("Client ID or client secret is malformed")
        }
        guard installed.projectID.range(of: "^[a-z][a-z0-9-]{4,61}[a-z0-9]$", options: .regularExpression) != nil else {
            throw OAuthError.invalidClientConfiguration("Project ID is malformed")
        }
        if let authURI = installed.authURI, !OAuthEndpoints.importedAuthorizationURIs.contains(authURI) {
            throw OAuthError.invalidClientConfiguration("Authorization endpoint is not a Google endpoint")
        }
        if let tokenURI = installed.tokenURI, tokenURI != OAuthEndpoints.token.absoluteString {
            throw OAuthError.invalidClientConfiguration("Token endpoint is not a Google endpoint")
        }
        return OAuthClientConfiguration(clientID: installed.clientID, clientSecret: installed.clientSecret, projectID: installed.projectID)
    }
}

public enum OAuthEndpoints {
    public static let authorization = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let importedAuthorizationURIs: Set<String> = [
        authorization.absoluteString,
        "https://accounts.google.com/o/oauth2/auth"
    ]
    public static let token = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revoke = URL(string: "https://oauth2.googleapis.com/revoke")!
    public static let userInfo = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
    public static let scopes = ["openid", "email", "https://www.googleapis.com/auth/generative-language.retriever"]
    public static let codeAssistScopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile"
    ]
}

public struct GeminiCLIOAuthClient: Sendable {
    public static let clientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    public static let clientSecret = "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"
    public static let redirectPath = "/oauth2callback"

    public static let signInSuccessURL = URL(string: "https://developers.google.com/gemini-code-assist/auth_success_gemini")!
    public static let signInFailureURL = URL(string: "https://developers.google.com/gemini-code-assist/auth_failure_gemini")!

    public static var configuration: OAuthClientConfiguration {
        OAuthClientConfiguration(clientID: clientID, clientSecret: clientSecret, projectID: "gemini-cli-project")
    }

    public static let codeAssistModelMappings: [String: String] = [
        "gemini-3.5-flash": "gemini-3-flash"
    ]

    public static let modelAliases: [String: String] = [
        "auto": "gemini-2.5-pro",
        "pro": "gemini-2.5-pro",
        "flash": "gemini-3.5-flash",
        "flash-lite": "gemini-2.5-flash"
    ]

    public static func authorizationURL(redirectURI: String, verifierChallenge: String, state: String, scopes: [String] = OAuthEndpoints.codeAssistScopes) throws -> URL {
        var components = URLComponents(url: OAuthEndpoints.authorization, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_challenge", value: verifierChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else { throw OAuthError.invalidClientConfiguration("Could not create authorization URL") }
        return url
    }
}

public struct OAuthTokenSet: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var subject: String
    public var email: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, subject: String, email: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.subject = subject
        self.email = email
    }
}

public struct OAuthProfile: Codable, Equatable, Sendable {
    public let id: String
    public var label: String
    public var backend: OAuthBackend
    public var oauthClientID: String
    public var subject: String
    public var companionProjectID: String?
    public var quotaProjectID: String?
    public var tierID: String?
    public var tierName: String?
    public var hasOnboarded: Bool
    public var modelPolicy: OAuthModelPolicy
    public var creditPolicy: CreditPolicy
    public var googleOneAICreditBalance: Int?

    public init(
        id: String,
        label: String,
        backend: OAuthBackend,
        oauthClientID: String,
        subject: String,
        companionProjectID: String? = nil,
        quotaProjectID: String? = nil,
        tierID: String? = nil,
        tierName: String? = nil,
        hasOnboarded: Bool = false,
        modelPolicy: OAuthModelPolicy = .default,
        creditPolicy: CreditPolicy = .never,
        googleOneAICreditBalance: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.backend = backend
        self.oauthClientID = oauthClientID
        self.subject = subject
        self.companionProjectID = companionProjectID
        self.quotaProjectID = quotaProjectID
        self.tierID = tierID
        self.tierName = tierName
        self.hasOnboarded = hasOnboarded
        self.modelPolicy = modelPolicy
        self.creditPolicy = creditPolicy
        self.googleOneAICreditBalance = googleOneAICreditBalance
    }

    public var effectiveProjectID: String {
        companionProjectID ?? quotaProjectID ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, label, backend, oauthClientID, subject, hasOnboarded, modelPolicy, creditPolicy, googleOneAICreditBalance
        case companionProjectID, quotaProjectID, tierID, tierName
        case projectID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        backend = try container.decodeIfPresent(OAuthBackend.self, forKey: .backend) ?? .codeAssist
        oauthClientID = try container.decodeIfPresent(String.self, forKey: .oauthClientID) ?? GeminiCLIOAuthClient.clientID
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        companionProjectID = try container.decodeIfPresent(String.self, forKey: .companionProjectID)
        quotaProjectID = try container.decodeIfPresent(String.self, forKey: .quotaProjectID)
        tierID = try container.decodeIfPresent(String.self, forKey: .tierID)
        tierName = try container.decodeIfPresent(String.self, forKey: .tierName)
        hasOnboarded = try container.decodeIfPresent(Bool.self, forKey: .hasOnboarded) ?? false
        modelPolicy = try container.decodeIfPresent(OAuthModelPolicy.self, forKey: .modelPolicy) ?? .default
        creditPolicy = try container.decodeIfPresent(CreditPolicy.self, forKey: .creditPolicy) ?? .never
        googleOneAICreditBalance = try container.decodeIfPresent(Int.self, forKey: .googleOneAICreditBalance)
        if companionProjectID == nil {
            let oldProject = try container.decodeIfPresent(String.self, forKey: .projectID)
            if let oldProject, oldProject != "gemini-cli-project" {
                companionProjectID = oldProject
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(backend, forKey: .backend)
        try container.encode(oauthClientID, forKey: .oauthClientID)
        try container.encode(subject, forKey: .subject)
        try container.encodeIfPresent(companionProjectID, forKey: .companionProjectID)
        try container.encodeIfPresent(quotaProjectID, forKey: .quotaProjectID)
        try container.encodeIfPresent(tierID, forKey: .tierID)
        try container.encodeIfPresent(tierName, forKey: .tierName)
        try container.encode(hasOnboarded, forKey: .hasOnboarded)
        try container.encode(modelPolicy, forKey: .modelPolicy)
        try container.encode(creditPolicy, forKey: .creditPolicy)
        try container.encodeIfPresent(googleOneAICreditBalance, forKey: .googleOneAICreditBalance)
    }

    public static func == (lhs: OAuthProfile, rhs: OAuthProfile) -> Bool {
        lhs.id == rhs.id &&
        lhs.label == rhs.label &&
        lhs.backend == rhs.backend &&
        lhs.oauthClientID == rhs.oauthClientID &&
        lhs.subject == rhs.subject &&
        lhs.companionProjectID == rhs.companionProjectID &&
        lhs.quotaProjectID == rhs.quotaProjectID &&
        lhs.tierID == rhs.tierID &&
        lhs.tierName == rhs.tierName &&
        lhs.hasOnboarded == rhs.hasOnboarded &&
        lhs.modelPolicy == rhs.modelPolicy &&
        lhs.creditPolicy == rhs.creditPolicy &&
        lhs.googleOneAICreditBalance == rhs.googleOneAICreditBalance
    }
}

public enum OAuthBackend: String, Codable, Sendable, CaseIterable {
    case codeAssist
    case publicGeminiAPI = "public-gemini-api"
}

public enum CreditPolicy: String, Codable, Sendable, CaseIterable {
    case never
    case ask
    case always
}

public struct OAuthModelPolicy: Codable, Equatable, Sendable {
    public var preferred: String
    public var fallbacks: [String]

    public init(preferred: String, fallbacks: [String]) {
        self.preferred = preferred
        self.fallbacks = fallbacks
    }

    public static let `default` = OAuthModelPolicy(preferred: "gemini-3.5-flash", fallbacks: ["gemini-2.5-flash"])
}

public struct OAuthRegistry: Codable, Equatable, Sendable {
    public var version: Int
    public var activeProfileID: String?
    public var profiles: [OAuthProfile]

    public init(version: Int = 2, activeProfileID: String? = nil, profiles: [OAuthProfile] = []) {
        self.version = version
        self.activeProfileID = activeProfileID
        self.profiles = profiles
    }

    enum CodingKeys: String, CodingKey {
        case version, activeProfileID, profiles
        case activeProfileIDLegacy = "active_profile_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        activeProfileID = try container.decodeIfPresent(String.self, forKey: .activeProfileID)
            ?? container.decodeIfPresent(String.self, forKey: .activeProfileIDLegacy)
        profiles = try container.decodeIfPresent([OAuthProfile].self, forKey: .profiles) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(activeProfileID, forKey: .activeProfileID)
        try container.encode(profiles, forKey: .profiles)
    }
}

public enum AuthenticationMode: String, Codable, CaseIterable, Sendable {
    case codeAssist = "code-assist"
    case publicOAuth = "public-oauth"
    case apiKey = "api-key"
    case oauth

    public var isOAuth: Bool { self != .apiKey }
    public var isCodeAssist: Bool { self == .codeAssist || self == .oauth }

    public init(backend: OAuthBackend) {
        self = backend == .codeAssist ? .codeAssist : .publicOAuth
    }

    public var backend: OAuthBackend? {
        switch self {
        case .codeAssist, .oauth: return .codeAssist
        case .publicOAuth: return .publicGeminiAPI
        case .apiKey: return nil
        }
    }
}

public struct OAuthProfileSummary: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let backend: OAuthBackend
    public let companionProjectID: String?
    public let maskedEmail: String
    public let tokenState: String
    public let hasOnboarded: Bool
    public let tierName: String?
    public let isActive: Bool

    public init(
        id: String,
        label: String,
        backend: OAuthBackend,
        companionProjectID: String?,
        maskedEmail: String,
        tokenState: String,
        hasOnboarded: Bool,
        tierName: String?,
        isActive: Bool
    ) {
        self.id = id
        self.label = label
        self.backend = backend
        self.companionProjectID = companionProjectID
        self.maskedEmail = maskedEmail
        self.tokenState = tokenState
        self.hasOnboarded = hasOnboarded
        self.tierName = tierName
        self.isActive = isActive
    }
}

public struct OAuthProfileSecret: Codable, Equatable, Sendable {
    public var configuration: OAuthClientConfiguration
    public var tokens: OAuthTokenSet
}
