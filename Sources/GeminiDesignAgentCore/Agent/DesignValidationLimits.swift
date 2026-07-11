enum DesignValidationLimits {
    static let maxElements = 1_000
    static let maxComponents = 500
    static let fontSizePx = 1...512
    static let lineHeightPx = 1...1_024
    static let letterSpacingPx = -64.0...64.0
    static let spacingPx = 0...4_096
    static let radiusPx = 0...4_096
    static let maxTextLength = 10_000
    static let maxHintLength = 1_000
    static let maxHierarchyDepth = 64
}
