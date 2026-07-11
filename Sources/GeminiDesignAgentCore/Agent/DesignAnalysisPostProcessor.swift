import Foundation

public enum DesignAnalysisPostProcessor {
    public static func validate(_ analysis: DesignAnalysis) -> DesignAnalysis {
        var updated = analysis
        var diagnostics = updated.diagnostics
        var ids = Set<String>()
        let sourceElementCount = analysis.elements.count
        updated.elements = analysis.elements.prefix(DesignValidationLimits.maxElements).compactMap { element in
            guard element.bbox1000.xmin >= 0, element.bbox1000.ymin >= 0,
                  element.bbox1000.xmax <= 1_000, element.bbox1000.ymax <= 1_000,
                  element.bbox1000.xmin <= element.bbox1000.xmax,
                  element.bbox1000.ymin <= element.bbox1000.ymax,
                  element.bbox1000.xmin < element.bbox1000.xmax,
                  element.bbox1000.ymin < element.bbox1000.ymax,
                  !element.id.isEmpty, !ids.contains(element.id) else {
                diagnostics.append(element.id.isEmpty || ids.contains(element.id) ? "element.dropped.duplicate_id" : "element.dropped.invalid_geometry")
                return nil
            }
            ids.insert(element.id)
            var value = element
            if !(0...1).contains(value.bbox1000.confidence) { diagnostics.append("element.confidence.clamped") }
            value.bbox1000.confidence = min(1, max(0, value.bbox1000.confidence))
            let originalColors = value.colorsHex
            value.colorsHex = Array(Set(value.colorsHex.compactMap(normalizedHex))).sorted()
            if value.colorsHex != originalColors { diagnostics.append("element.color.invalid_removed") }
            if var typography = value.typography {
                if typography.fontSizePx.map({ !DesignValidationLimits.fontSizePx.contains($0) }) == true { typography.fontSizePx = nil; diagnostics.append("element.typography.font_size_removed") }
                if typography.lineHeightPx.map({ !DesignValidationLimits.lineHeightPx.contains($0) }) == true { typography.lineHeightPx = nil; diagnostics.append("element.typography.line_height_removed") }
                if typography.letterSpacingPx.map({ !DesignValidationLimits.letterSpacingPx.contains($0) }) == true { typography.letterSpacingPx = nil; diagnostics.append("element.typography.letter_spacing_removed") }
                let originalColor = typography.colorHex
                typography.colorHex = typography.colorHex.flatMap(normalizedHex)
                if typography.colorHex != originalColor { diagnostics.append("element.typography.color_removed_or_normalized") }
                if !(0...1).contains(typography.confidence) { diagnostics.append("element.typography.confidence_clamped") }
                typography.confidence = min(1, max(0, typography.confidence))
                value.typography = typography
            }
            if var spacing = value.spacing {
                let values = [spacing.top, spacing.right, spacing.bottom, spacing.left, spacing.vertical, spacing.horizontal]
                if values.contains(where: { $0.map { !DesignValidationLimits.spacingPx.contains($0) } == true }) { diagnostics.append("element.spacing.invalid_removed") }
                if spacing.top.map({ !DesignValidationLimits.spacingPx.contains($0) }) == true { spacing.top = nil }
                if spacing.right.map({ !DesignValidationLimits.spacingPx.contains($0) }) == true { spacing.right = nil }
                if spacing.bottom.map({ !DesignValidationLimits.spacingPx.contains($0) }) == true { spacing.bottom = nil }
                if spacing.left.map({ !DesignValidationLimits.spacingPx.contains($0) }) == true { spacing.left = nil }
                if spacing.vertical.map({ !DesignValidationLimits.spacingPx.contains($0) }) == true { spacing.vertical = nil }
                if spacing.horizontal.map({ !DesignValidationLimits.spacingPx.contains($0) }) == true { spacing.horizontal = nil }
                if !(0...1).contains(spacing.confidence) { diagnostics.append("element.spacing.confidence_clamped") }
                spacing.confidence = min(1, max(0, spacing.confidence)); value.spacing = spacing
            }
            if value.borderRadiusPx.map({ !DesignValidationLimits.radiusPx.contains($0) }) == true { value.borderRadiusPx = nil; diagnostics.append("element.radius.invalid_removed") }
            let originalText = value.visibleText
            value.visibleText = value.visibleText.map { String($0.prefix(DesignValidationLimits.maxTextLength)) }
            if value.visibleText != originalText { diagnostics.append("element.visible_text.truncated") }
            let originalChildren = value.children
            value.children = Array(Set(value.children.filter { $0 != value.id })).sorted()
            if value.children != originalChildren { diagnostics.append("element.children.invalid_reference_removed") }
            return value
        }
        if sourceElementCount > DesignValidationLimits.maxElements { diagnostics.append("element.dropped.limit_exceeded") }
        let validIDs = Set(updated.elements.map(\.id))
        updated.elements = updated.elements.map { element in
            var value = element
            let oldChildren = value.children
            value.children = oldChildren.filter(validIDs.contains)
            if oldChildren.count != value.children.count { diagnostics.append("element.children.invalid_reference_removed") }
            return value
        }
        let originalColorTokens = updated.tokens.colors
        updated.tokens.colors = updated.tokens.colors.prefix(DesignValidationLimits.maxTokenItems).compactMap { token in
            guard let hex = normalizedHex(token.hex) else {
                diagnostics.append("token.color.invalid_removed")
                return nil
            }
            var value = token
            value.hex = hex
            if !(0...1).contains(value.confidence) { diagnostics.append("token.color.confidence_clamped") }
            value.confidence = min(1, max(0, value.confidence))
            return value
        }
        if updated.tokens.colors.count != originalColorTokens.count { diagnostics.append("token.color.limit_or_invalid_removed") }
        let originalTypographyTokens = updated.tokens.typography
        updated.tokens.typography = updated.tokens.typography.prefix(DesignValidationLimits.maxTokenItems).compactMap {
            guard DesignValidationLimits.fontSizePx.contains($0.fontSizePx), $0.lineHeightPx.map(DesignValidationLimits.lineHeightPx.contains) != false else { diagnostics.append("token.typography.invalid_removed"); return nil }
            var value = $0
            if !(0...1).contains(value.confidence) { diagnostics.append("token.typography.confidence_clamped") }
            value.confidence = min(1, max(0, value.confidence))
            return value
        }
        if updated.tokens.typography.count != originalTypographyTokens.count { diagnostics.append("token.typography.limit_or_invalid_removed") }
        let originalSpacing = updated.tokens.spacingScalePx
        updated.tokens.spacingScalePx = Array(Set(updated.tokens.spacingScalePx.filter(DesignValidationLimits.spacingPx.contains))).sorted().prefix(DesignValidationLimits.maxTokenItems).map { $0 }
        if updated.tokens.spacingScalePx != originalSpacing { diagnostics.append("token.spacing.invalid_removed") }
        let originalRadii = updated.tokens.radiiPx
        updated.tokens.radiiPx = Array(Set(updated.tokens.radiiPx.filter(DesignValidationLimits.radiusPx.contains))).sorted().prefix(DesignValidationLimits.maxTokenItems).map { $0 }
        if updated.tokens.radiiPx != originalRadii { diagnostics.append("token.radius.invalid_removed") }
        let originalShadows = updated.tokens.shadows
        updated.tokens.shadows = Array(Set(updated.tokens.shadows.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.count <= DesignValidationLimits.maxHintLength })).sorted().prefix(DesignValidationLimits.maxTokenItems).map { $0 }
        if updated.tokens.shadows != originalShadows { diagnostics.append("token.shadow.invalid_removed") }
        var componentIDs = Set<String>()
        updated.components = updated.components.prefix(DesignValidationLimits.maxComponents).compactMap {
            guard !$0.id.isEmpty, !componentIDs.contains($0.id) else { diagnostics.append("component.dropped.duplicate_id"); return nil }
            componentIDs.insert($0.id)
            var value = $0
            if !(0...1).contains(value.confidence) { diagnostics.append("component.confidence.clamped") }
            value.confidence = min(1, max(0, value.confidence))
            let originalElementIDs = value.elementIds
            value.elementIds = Array(Set(value.elementIds.filter(validIDs.contains))).sorted()
            if value.elementIds != originalElementIDs { diagnostics.append("component.element_reference.invalid_removed") }
            let originalName = value.name
            let originalDescription = value.description
            value.name = String(value.name.prefix(DesignValidationLimits.maxHintLength))
            value.description = String(value.description.prefix(DesignValidationLimits.maxTextLength))
            if value.name != originalName || value.description != originalDescription { diagnostics.append("component.text.truncated") }
            let originalHints = value.styleHints
            value.styleHints = value.styleHints.reduce(into: [:]) { partial, entry in
                guard entry.key.count <= DesignValidationLimits.maxHintLength, entry.value.count <= DesignValidationLimits.maxHintLength else { return }
                partial[entry.key] = entry.value
            }
            if value.styleHints != originalHints { diagnostics.append("component.style_hint.invalid_removed") }
            return value
        }
        var hierarchyIDs = Set<String>()
        func validNode(_ node: HierarchyNode, depth: Int, ancestors: Set<String>) -> HierarchyNode? {
            guard depth <= DesignValidationLimits.maxHierarchyDepth, !node.id.isEmpty, validIDs.contains(node.elementId), !ancestors.contains(node.id), !hierarchyIDs.contains(node.id) else {
                diagnostics.append("hierarchy.invalid_removed")
                return nil
            }
            hierarchyIDs.insert(node.id)
            var value = node
            if value.depth != depth { diagnostics.append("hierarchy.depth.recomputed") }
            value.depth = depth
            if node.children.count > DesignValidationLimits.maxHierarchyChildren { diagnostics.append("hierarchy.children.limit_exceeded") }
            value.children = node.children.prefix(DesignValidationLimits.maxHierarchyChildren).compactMap { validNode($0, depth: depth + 1, ancestors: ancestors.union([node.id])) }
            return value
        }
        updated.hierarchy = updated.hierarchy.compactMap { validNode($0, depth: 0, ancestors: []) }
        if diagnostics.count > analysis.diagnostics.count { diagnostics.append("analysis.validation.modified") }
        if sourceElementCount > 0, updated.elements.count * 2 < sourceElementCount { diagnostics.append("analysis.validation.high_drop_rate") }
        updated.diagnostics = Array(Set(diagnostics)).sorted()
        return updated
    }

    private static func normalizedHex(_ value: String) -> String? {
        let characters = Array(value.utf8)
        guard (characters.count == 7 || characters.count == 9), characters.first == Character("#").asciiValue,
              characters.dropFirst().allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return value.uppercased()
    }

    public static func fillPixelBoxes(_ analysis: DesignAnalysis, imageWidth: Int, imageHeight: Int) -> DesignAnalysis {
        var updated = analysis

        updated.elements = analysis.elements.map { element in
            var el = element
            el.bboxPx = convertBBoxToPixels(el.bbox1000, imageWidth: imageWidth, imageHeight: imageHeight)
            return el
        }

        return updated
    }

    public static func attachRunMetadata(
        _ analysis: DesignAnalysis,
        runId: String,
        projectId: String,
        model: String,
        screenName: String?,
        evidenceIds: [String]
    ) -> DesignAnalysis {
        var updated = analysis

        updated.run = RunSummary(
            id: runId,
            projectId: projectId,
            screenName: screenName,
            model: model,
            startedAt: Date()
        )

        return updated
    }
}
