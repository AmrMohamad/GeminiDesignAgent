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
        evidenceId: String,
        memoryAtomIds: [String] = []
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
                memoryAtomIds: memoryAtomIds,
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
                    memoryAtomIds: Array(Set(existing.memoryAtomIds + memoryAtomIds)).sorted(),
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
                merged.spacingScalePx = Array(Set(existing.spacingScalePx + profile.spacingScalePx)).sorted().prefixArray(24)
                merged.radiiPx = Array(Set(existing.radiiPx + profile.radiiPx)).sorted().prefixArray(16)
                merged.shadows = Array(Set(existing.shadows + profile.shadows)).prefixArray(16)
                merged.components = mergeComponents(existing.components, profile.components)
                merged.implementationPreferences = Array(Set(existing.implementationPreferences + profile.implementationPreferences)).prefixArray(24)
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
        let values = (existing.split(separator: "|") + new.split(separator: "|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for value in values where !unique.contains(value) { unique.append(value) }
        let recent = unique.suffix(4).joined(separator: " | ")
        return String(recent.prefix(2_000))
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
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence { return lhs.name < rhs.name }
                return lhs.confidence > rhs.confidence
            }
            .prefixArray(24)
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
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence { return lhs.name < rhs.name }
                return lhs.confidence > rhs.confidence
            }
            .prefixArray(24)
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
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence { return lhs.name < rhs.name }
                return lhs.confidence > rhs.confidence
            }
            .prefixArray(32)
    }
}

private extension Array {
    func prefixArray(_ maxCount: Int) -> [Element] {
        Array(prefix(maxCount))
    }
}
