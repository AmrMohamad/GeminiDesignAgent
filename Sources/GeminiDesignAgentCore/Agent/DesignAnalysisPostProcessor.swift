import Foundation

public enum DesignAnalysisPostProcessor {
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
