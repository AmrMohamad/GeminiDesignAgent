import Foundation

public enum DesignAnalysisPostProcessor {
    public static func validate(_ analysis: DesignAnalysis) -> DesignAnalysis {
        var updated = analysis
        var diagnostics = updated.diagnostics
        var ids = Set<String>()
        let validHex = try? NSRegularExpression(pattern: "^#[0-9A-Fa-f]{6}$")
        updated.elements = analysis.elements.compactMap { element in
            guard element.bbox1000.xmin >= 0, element.bbox1000.ymin >= 0,
                  element.bbox1000.xmax <= 1_000, element.bbox1000.ymax <= 1_000,
                  element.bbox1000.xmin <= element.bbox1000.xmax,
                  element.bbox1000.ymin <= element.bbox1000.ymax,
                  !element.id.isEmpty, !ids.contains(element.id) else {
                diagnostics.append("element.dropped.invalid_geometry_or_id")
                return nil
            }
            ids.insert(element.id)
            var value = element
            value.bbox1000.confidence = min(1, max(0, value.bbox1000.confidence))
            value.colorsHex = value.colorsHex.filter {
                validHex?.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
            }
            value.children = value.children.filter { $0 != value.id }
            return value
        }
        let validIDs = Set(updated.elements.map(\.id))
        updated.elements = updated.elements.map { element in
            var value = element
            let oldChildren = value.children
            value.children = oldChildren.filter(validIDs.contains)
            if oldChildren.count != value.children.count { diagnostics.append("element.children.invalid_reference_removed") }
            if var typography = value.typography { typography.confidence = min(1, max(0, typography.confidence)); value.typography = typography }
            if var spacing = value.spacing { spacing.confidence = min(1, max(0, spacing.confidence)); value.spacing = spacing }
            return value
        }
        updated.diagnostics = Array(Set(diagnostics)).sorted()
        return updated
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
