import Foundation

public struct MemoryCompactor: Sendable {
    private let store: DesignMemoryStore
    private let projectId: String

    public init(store: DesignMemoryStore, projectId: String) {
        self.store = store
        self.projectId = projectId
    }

    public func updateSceneAndProfileFastPath(
        from analysis: DesignAnalysis,
        screenName: String,
        runId: String,
        evidenceId: String
    ) async throws -> (sceneUpdated: Bool, profileUpdated: Bool) {
        var sceneUpdated = false
        var profileUpdated = false

        if let sceneSummary = buildSceneSummary(from: analysis, screenName: screenName) {
            let sceneId = StableID.scene()
            var scene = SceneBlock(
                id: sceneId,
                projectId: projectId,
                name: screenName,
                summary: sceneSummary,
                keyComponents: analysis.components.map { $0.name },
                keyTokens: analysis.tokens.colors.map { "\($0.name):\($0.hex)" },
                evidenceIds: [evidenceId]
            )

            if let existing = try await store.getSceneBlock(name: screenName) {
                scene = SceneBlock(
                    id: existing.id,
                    projectId: projectId,
                    name: screenName,
                    summary: mergeSummaries(existing.summary, sceneSummary),
                    keyComponents: Array(Set(existing.keyComponents + scene.keyComponents)),
                    keyTokens: Array(Set(existing.keyTokens + scene.keyTokens)),
                    evidenceIds: Array(Set(existing.evidenceIds + [evidenceId]))
                )
            }

            try await store.upsertSceneBlock(scene)
            sceneUpdated = true
        }

        if let profile = buildProjectProfileUpdate(from: analysis) {
            if let existing = try await store.getProjectProfile() {
                var merged = existing
                merged.styleSummary = mergeSummaries(existing.styleSummary, profile.styleSummary)
                merged.brandColors = mergeColorTokens(existing.brandColors, profile.brandColors)
                merged.typographyScale = mergeTypographyTokens(existing.typographyScale, profile.typographyScale)
                merged.spacingScalePx = Array(Set(existing.spacingScalePx + profile.spacingScalePx)).sorted()
                merged.radiiPx = Array(Set(existing.radiiPx + profile.radiiPx)).sorted()
                merged.shadows = Array(Set(existing.shadows + profile.shadows))
                merged.components = mergeComponents(existing.components, profile.components)
                merged.implementationPreferences = Array(Set(existing.implementationPreferences + profile.implementationPreferences))
                merged.updatedAt = Date()
                try await store.upsertProjectProfile(merged)
            } else {
                try await store.upsertProjectProfile(profile)
            }
            profileUpdated = true
        }

        return (sceneUpdated, profileUpdated)
    }

    private func buildSceneSummary(from analysis: DesignAnalysis, screenName: String) -> String? {
        if !analysis.summary.isEmpty {
            return "\(screenName): \(analysis.summary)"
        }
        return nil
    }

    private func buildProjectProfileUpdate(from analysis: DesignAnalysis) -> ProjectProfile? {
        guard !analysis.tokens.colors.isEmpty || !analysis.tokens.typography.isEmpty else {
            return nil
        }

        return ProjectProfile(
            projectId: projectId,
            styleSummary: analysis.summary,
            brandColors: analysis.tokens.colors,
            typographyScale: analysis.tokens.typography,
            spacingScalePx: analysis.tokens.spacingScalePx,
            radiiPx: analysis.tokens.radiiPx,
            shadows: analysis.tokens.shadows,
            components: analysis.components.map {
                ComponentProfile(name: $0.name, type: $0.type, description: $0.description, styleHints: $0.styleHints, confidence: $0.confidence)
            },
            implementationPreferences: analysis.implementation?.notes ?? []
        )
    }

    private func mergeSummaries(_ existing: String, _ new: String) -> String {
        if existing.contains(new) { return existing }
        if new.contains(existing) { return new }
        return existing + " | " + new
    }

    private func mergeColorTokens(_ existing: [NamedColorToken], _ new: [NamedColorToken]) -> [NamedColorToken] {
        var map = [String: NamedColorToken]()
        for c in existing { map[c.name.lowercased()] = c }
        for c in new {
            let key = c.name.lowercased()
            if let old = map[key] {
                if c.confidence > old.confidence { map[key] = c }
            } else {
                map[key] = c
            }
        }
        return Array(map.values)
    }

    private func mergeTypographyTokens(_ existing: [TypographyToken], _ new: [TypographyToken]) -> [TypographyToken] {
        var map = [String: TypographyToken]()
        for t in existing { map[t.name.lowercased()] = t }
        for t in new {
            let key = t.name.lowercased()
            if let old = map[key] {
                if t.confidence > old.confidence { map[key] = t }
            } else {
                map[key] = t
            }
        }
        return Array(map.values)
    }

    private func mergeComponents(_ existing: [ComponentProfile], _ new: [ComponentProfile]) -> [ComponentProfile] {
        var map = [String: ComponentProfile]()
        for c in existing { map[c.name.lowercased()] = c }
        for c in new {
            let key = c.name.lowercased()
            if let old = map[key] {
                var merged = old
                merged.styleHints.merge(c.styleHints) { _, new in new }
                if c.confidence > old.confidence { merged.confidence = c.confidence }
                map[key] = merged
            } else {
                map[key] = c
            }
        }
        return Array(map.values)
    }
}
