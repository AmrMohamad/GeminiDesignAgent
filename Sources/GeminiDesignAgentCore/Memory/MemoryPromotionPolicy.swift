public enum MemoryPromotionPolicy {
    public static let automaticallyPromotableTypes: Set<MemoryAtomType> = [
        .projectStyle, .designToken, .component, .layoutRule, .spacingRule, .typographyRule
    ]

    public static func canPromote(candidate: MemoryAtom, supporting: MemoryAtom, matchingNormalizedContent: Bool) -> Bool {
        guard automaticallyPromotableTypes.contains(candidate.type),
              candidate.type == supporting.type,
              candidate.scope == .screen,
              supporting.scope == .screen,
              candidate.confidence >= 0.75,
              matchingNormalizedContent,
              let candidateScreen = candidate.sceneName, !candidateScreen.isEmpty,
              let supportingScreen = supporting.sceneName, !supportingScreen.isEmpty,
              candidateScreen != supportingScreen,
              candidate.componentName == supporting.componentName else {
            return false
        }
        let evidence = Set(candidate.sourceEvidenceIds).union(supporting.sourceEvidenceIds)
        return evidence.count >= 2
    }
}
