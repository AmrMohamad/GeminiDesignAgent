import Foundation

public final class OAuthProfileStore: @unchecked Sendable {
    private static let namespace = "oauth"
    private let registryStore = SecureCredentialStore(namespace: namespace, slot: "registry-v1")
    private let modeStore = SecureCredentialStore(namespace: namespace, slot: "mode-v1")

    public init() {}

    public var persistenceDescription: String { registryStore.persistenceDescription }

    public func loadRegistry() throws -> OAuthRegistry {
        guard let value = try registryStore.load() else { return OAuthRegistry() }
        guard let data = value.data(using: .utf8) else { throw APIKeyStoreError.invalidEncoding }
        do {
            var registry = try JSONDecoder().decode(OAuthRegistry.self, from: data)
            if registry.version < 2 {
                registry = migrateV1toV2(registry)
                try saveRegistry(registry)
            }
            return registry
        } catch {
            throw OAuthError.credentialStoreUnavailable("OAuth registry is invalid")
        }
    }

    public func saveRegistry(_ registry: OAuthRegistry) throws {
        let data = try JSONEncoder().encode(registry)
        guard let value = String(data: data, encoding: .utf8) else { throw APIKeyStoreError.invalidEncoding }
        try registryStore.save(value)
    }

    public func loadMode() throws -> AuthenticationMode? {
        guard let value = try modeStore.load() else { return nil }
        guard let mode = AuthenticationMode(rawValue: value) else { return nil }
        guard mode == .oauth else { return mode }
        let migrated = try activeProfile().map { AuthenticationMode(backend: $0.0.backend) } ?? .codeAssist
        try saveMode(migrated)
        return migrated
    }

    public func saveMode(_ mode: AuthenticationMode) throws {
        try modeStore.save(mode.rawValue)
    }

    public func loadSecret(profileID: String) throws -> OAuthProfileSecret? {
        guard let value = try SecureCredentialStore(namespace: Self.namespace, slot: "profile.\(profileID)").load() else {
            return nil
        }
        guard let data = value.data(using: .utf8) else { throw APIKeyStoreError.invalidEncoding }
        do {
            return try JSONDecoder().decode(OAuthProfileSecret.self, from: data)
        } catch {
            return nil
        }
    }

    public func saveSecret(_ secret: OAuthProfileSecret, profileID: String) throws {
        let data = try JSONEncoder().encode(secret)
        guard let value = String(data: data, encoding: .utf8) else { throw APIKeyStoreError.invalidEncoding }
        try SecureCredentialStore(namespace: Self.namespace, slot: "profile.\(profileID)").save(value)
    }

    public func deleteSecret(profileID: String) throws {
        try SecureCredentialStore(namespace: Self.namespace, slot: "profile.\(profileID)").delete()
    }

    public func activeProfile() throws -> (OAuthProfile, OAuthProfileSecret)? {
        let registry = try loadRegistry()
        guard let id = registry.activeProfileID,
              let profile = registry.profiles.first(where: { $0.id == id }),
              let secret = try loadSecret(profileID: id) else {
            return nil
        }
        return (profile, secret)
    }

    public func profile(id: String) throws -> (OAuthProfile, OAuthProfileSecret) {
        let registry = try loadRegistry()
        guard let profile = registry.profiles.first(where: { $0.id == id }) else {
            throw OAuthError.profileNotFound
        }
        guard let secret = try loadSecret(profileID: id) else {
            throw OAuthError.profileNotFound
        }
        return (profile, secret)
    }

    public func profileSummaries(now: Date = Date()) throws -> [OAuthProfileSummary] {
        let registry = try loadRegistry()
        return registry.profiles.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }.map { profile in
            let secret = try? loadSecret(profileID: profile.id)
            let tokenState: String
            if secret == nil {
                tokenState = "missing"
            } else if secret!.tokens.expiresAt <= now {
                tokenState = "refresh-needed"
            } else {
                tokenState = "valid"
            }
            return OAuthProfileSummary(
                id: profile.id,
                label: profile.label,
                backend: profile.backend,
                companionProjectID: profile.companionProjectID,
                maskedEmail: Self.maskedEmail(secret?.tokens.email),
                tokenState: tokenState,
                hasOnboarded: profile.hasOnboarded,
                tierName: profile.tierName,
                isActive: registry.activeProfileID == profile.id
            )
        }
    }

    public func upsert(
        label: String?,
        backend: OAuthBackend,
        configuration: OAuthClientConfiguration,
        tokens: OAuthTokenSet
    ) throws -> OAuthProfile {
        var registry = try loadRegistry()
        let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedLabel, normalizedLabel.isEmpty {
            throw OAuthError.invalidClientConfiguration("Profile label cannot be empty")
        }

        var existingIndex: Int?
        for index in registry.profiles.indices {
            let p = registry.profiles[index]
            if p.backend == backend && p.oauthClientID == configuration.clientID && p.subject == tokens.subject {
                existingIndex = index
                break
            }
        }

        let profile: OAuthProfile
        if let existingIndex {
            if let normalizedLabel {
                registry.profiles[existingIndex].label = normalizedLabel
            }
            profile = registry.profiles[existingIndex]
        } else {
            let resolvedLabel = normalizedLabel ?? Self.nextAutomaticLabel(in: registry)
            let isCodeAssist = backend == .codeAssist
            let companionProject: String? = isCodeAssist ? nil : configuration.projectID
            profile = OAuthProfile(
                id: UUID().uuidString.lowercased(),
                label: resolvedLabel,
                backend: backend,
                oauthClientID: configuration.clientID,
                subject: tokens.subject,
                companionProjectID: companionProject,
                quotaProjectID: isCodeAssist ? nil : configuration.projectID
            )
            registry.profiles.append(profile)
        }

        let existingSecret = try loadSecret(profileID: profile.id)
        let refreshToken = tokens.refreshToken.isEmpty ? (existingSecret?.tokens.refreshToken ?? tokens.refreshToken) : tokens.refreshToken
        let mergedTokens = OAuthTokenSet(
            accessToken: tokens.accessToken,
            refreshToken: refreshToken,
            expiresAt: tokens.expiresAt,
            subject: tokens.subject,
            email: tokens.email
        )
        try saveSecret(OAuthProfileSecret(configuration: configuration, tokens: mergedTokens), profileID: profile.id)
        registry.activeProfileID = profile.id
        try saveRegistry(registry)
        try saveMode(backend == .codeAssist ? .codeAssist : .publicOAuth)
        return profile
    }

    public func updateCompanionProject(profileID: String, projectID: String, tierID: String?, tierName: String?) throws -> OAuthProfile {
        var registry = try loadRegistry()
        guard let index = registry.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw OAuthError.profileNotFound
        }
        registry.profiles[index].companionProjectID = projectID
        registry.profiles[index].tierID = tierID
        registry.profiles[index].tierName = tierName
        registry.profiles[index].hasOnboarded = true
        try saveRegistry(registry)
        return registry.profiles[index]
    }

    public func updateModelPolicy(profileID: String, policy: OAuthModelPolicy) throws -> OAuthProfile {
        var registry = try loadRegistry()
        guard let index = registry.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw OAuthError.profileNotFound
        }
        registry.profiles[index].modelPolicy = policy
        try saveRegistry(registry)
        return registry.profiles[index]
    }

    public func updateCreditPolicy(profileID: String, policy: CreditPolicy) throws -> OAuthProfile {
        var registry = try loadRegistry()
        guard let index = registry.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw OAuthError.profileNotFound
        }
        registry.profiles[index].creditPolicy = policy
        try saveRegistry(registry)
        return registry.profiles[index]
    }

    public func updateGoogleOneAICreditBalance(profileID: String, balance: Int?) throws -> OAuthProfile {
        var registry = try loadRegistry()
        guard let index = registry.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw OAuthError.profileNotFound
        }
        registry.profiles[index].googleOneAICreditBalance = balance
        try saveRegistry(registry)
        return registry.profiles[index]
    }

    public func select(profileID: String) throws -> OAuthProfile {
        var registry = try loadRegistry()
        guard let profile = registry.profiles.first(where: { $0.id == profileID }) else {
            throw OAuthError.profileNotFound
        }
        guard try loadSecret(profileID: profileID) != nil else { throw OAuthError.profileNotFound }
        registry.activeProfileID = profileID
        try saveRegistry(registry)
        return profile
    }

    public func remove(profileID: String) throws {
        var registry = try loadRegistry()
        guard registry.profiles.contains(where: { $0.id == profileID }) else { throw OAuthError.profileNotFound }
        try? deleteSecret(profileID: profileID)
        registry.profiles.removeAll { $0.id == profileID }
        if registry.activeProfileID == profileID { registry.activeProfileID = nil }
        try saveRegistry(registry)
    }

    public func removeLocalOnly(profileID: String) throws {
        var registry = try loadRegistry()
        guard registry.profiles.contains(where: { $0.id == profileID }) else { throw OAuthError.profileNotFound }
        registry.profiles.removeAll { $0.id == profileID }
        if registry.activeProfileID == profileID { registry.activeProfileID = nil }
        try saveRegistry(registry)
    }

    private static func nextAutomaticLabel(in registry: OAuthRegistry) -> String {
        let base = "Google Account"
        let existing = Set(registry.profiles.map { $0.label.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private static func maskedEmail(_ email: String?) -> String {
        guard let email, let at = email.firstIndex(of: "@") else { return "unavailable" }
        let local = email[..<at]
        let domain = email[email.index(after: at)...]
        guard let first = local.first else { return "***@\(domain)" }
        return "\(first)***@\(domain)"
    }

    private func migrateV1toV2(_ old: OAuthRegistry) -> OAuthRegistry {
        var migrated = OAuthRegistry(version: 2, activeProfileID: old.activeProfileID, profiles: [])
        for oldProfile in old.profiles {
            let isCodeAssist = oldProfile.oauthClientID == GeminiCLIOAuthClient.clientID || oldProfile.oauthClientID.isEmpty
            let backend: OAuthBackend = isCodeAssist ? .codeAssist : .publicGeminiAPI
            let clientID = oldProfile.oauthClientID.isEmpty ? GeminiCLIOAuthClient.clientID : oldProfile.oauthClientID
            let companionProject: String?
            if oldProfile.effectiveProjectID == "gemini-cli-project" || oldProfile.effectiveProjectID.isEmpty {
                companionProject = nil
            } else {
                companionProject = oldProfile.effectiveProjectID
            }
            let migratedProfile = OAuthProfile(
                id: oldProfile.id,
                label: oldProfile.label,
                backend: backend,
                oauthClientID: clientID,
                subject: oldProfile.subject,
                companionProjectID: companionProject,
                modelPolicy: oldProfile.modelPolicy,
                creditPolicy: oldProfile.creditPolicy
            )
            migrated.profiles.append(migratedProfile)
        }
        return migrated
    }
}
