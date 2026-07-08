import Foundation

public struct AnalyzeScreenInput: Sendable {
    public var imageURL: URL
    public var screenName: String
    public var request: String
    public var model: String
    public var memoryLimit: Int
    public var debugPrompt: Bool
    public var storeArtifacts: Bool
    public var devicePixelRatio: Double
    public var viewport: String?
    public var theme: String?
    public var state: String?
    public var localeDirection: String?

    public init(
        imageURL: URL,
        screenName: String,
        request: String = "Extract layout, spacing, typography, colors, reusable components, and development-ready implementation values.",
        model: String = "gemini-2.5-flash",
        memoryLimit: Int = 8,
        debugPrompt: Bool = false,
        storeArtifacts: Bool = true,
        devicePixelRatio: Double = 1.0,
        viewport: String? = nil,
        theme: String? = nil,
        state: String? = nil,
        localeDirection: String? = nil
    ) {
        self.imageURL = imageURL
        self.screenName = screenName
        self.request = request
        self.model = model
        self.memoryLimit = memoryLimit
        self.debugPrompt = debugPrompt
        self.storeArtifacts = storeArtifacts
        self.devicePixelRatio = devicePixelRatio
        self.viewport = viewport
        self.theme = theme
        self.state = state
        self.localeDirection = localeDirection
    }
}

public actor GeminiDesignSession {
    private let context: RuntimeContext
    private let gemini: any GeminiDesignAnalyzing
    private let memory: DesignMemoryStore
    private let paths: ArtifactPaths

    public init(
        context: RuntimeContext,
        gemini: any GeminiDesignAnalyzing,
        memory: DesignMemoryStore,
        paths: ArtifactPaths
    ) {
        self.context = context
        self.gemini = gemini
        self.memory = memory
        self.paths = paths
    }

    public func analyzeScreen(_ input: AnalyzeScreenInput) async throws -> AnalyzeResult {
        let runId = StableID.run()
        var phase = "preflight"
        let imageInfo = try ImageInfoReader.read(input.imageURL)
        let startedAt = Date()
        var rawResponsePath: String?

        try validateImageForInlineUpload(input.imageURL)

        try memory.insertRun(
            id: runId,
            sessionId: context.sessionId,
            screenName: input.screenName,
            imagePath: input.imageURL.path,
            model: input.model,
            request: input.request,
            status: "started",
            startedAt: startedAt,
            completedAt: nil,
            error: nil
        )

        do {
            phase = "preflighted"
            try memory.updateRunStatus(id: runId, status: phase, completedAt: nil, error: nil)

            phase = "memory_retrieval"
            let injection = try await MemoryInjectionBuilder(memory: memory).build(
                screenName: input.screenName,
                request: input.request,
                limit: input.memoryLimit
            )

            phase = "prompt_built"
            let prompt = DesignPromptBuilder.build(
                screenName: input.screenName,
                request: input.request,
                imageInfo: imageInfo,
                memory: injection
            )

            if input.debugPrompt && input.storeArtifacts {
                try await savePromptSnapshot(runId: runId, system: prompt.system, user: prompt.user)
            }

            phase = "gemini_request"
            let raw = try await gemini.analyzeImage(
                model: input.model,
                imageURL: input.imageURL,
                mimeType: imageInfo.mimeType,
                systemInstruction: prompt.system,
                userPrompt: prompt.user,
                responseSchema: GeminiJSONSchema.designAnalysis
            )

            phase = "gemini_completed"
            try memory.updateRunStatus(id: runId, status: phase, completedAt: nil, error: nil)

            let evidenceId = try await saveRawResponse(
                runId: runId,
                screenName: input.screenName,
                raw: raw,
                storeArtifact: input.storeArtifacts,
                artifactDate: startedAt,
                savedPath: &rawResponsePath
            )

            var analysis: DesignAnalysis
            do {
                analysis = try JSON.decoder.decode(DesignAnalysis.self, from: raw.data)
            } catch {
                Logger.warn("Gemini JSON decode failed, attempting repair: \(error)")
                let repaired = try await repairJSON(rawText: raw.text, model: input.model)
                analysis = repaired
            }

            phase = "post_processing"
            analysis = DesignAnalysisPostProcessor.fillPixelBoxes(
                analysis,
                imageWidth: imageInfo.width,
                imageHeight: imageInfo.height
            )
            analysis = attachLogicalBoxes(analysis, devicePixelRatio: input.devicePixelRatio)

            analysis = DesignAnalysisPostProcessor.attachRunMetadata(
                analysis,
                runId: runId,
                projectId: context.projectId,
                model: input.model,
                screenName: input.screenName,
                evidenceIds: [evidenceId]
            )

            analysis.image = ImageSummary(
                widthPx: imageInfo.width,
                heightPx: imageInfo.height,
                mimeType: imageInfo.mimeType,
                devicePixelRatio: input.devicePixelRatio,
                viewport: input.viewport,
                theme: input.theme,
                state: input.state,
                localeDirection: input.localeDirection
            )

            phase = "analysis_saved"
            let analysisPath = try await saveAnalysis(
                runId: runId,
                analysis: analysis,
                storeArtifact: input.storeArtifacts
            )
            try memory.updateRunStatus(id: runId, status: phase, completedAt: nil, error: nil)

            phase = "memory_written"
            let writtenAtomIds = try await MemoryWriter(store: memory).applyWrites(
                analysis.memoryWrites,
                sourceEvidenceIds: [evidenceId],
                projectId: context.projectId,
                screenName: input.screenName
            )
            try memory.updateRunStatus(id: runId, status: phase, completedAt: nil, error: nil)

            phase = "compacted"
            let compactor = MemoryCompactor(store: memory, projectId: context.projectId)
            let compactionResult = try await compactor.updateSceneAndProfileFastPath(
                from: analysis,
                screenName: input.screenName,
                runId: runId,
                evidenceId: evidenceId
            )
            try memory.updateRunStatus(id: runId, status: phase, completedAt: nil, error: nil)

            try memory.updateRunStatus(
                id: runId,
                status: "completed",
                completedAt: Date(),
                error: nil
            )

            let usedAtomIds = injection.atoms.map { $0.atom.id }

            return AnalyzeResult(
                ok: true,
                runId: runId,
                projectId: context.projectId,
                screen: input.screenName,
                model: input.model,
                analysis: analysis,
                memory: AnalyzeMemoryInfo(
                    usedAtomIds: usedAtomIds,
                    writtenAtomIds: writtenAtomIds,
                    sceneUpdated: compactionResult.sceneUpdated,
                    profileUpdated: compactionResult.profileUpdated
                ),
                artifacts: AnalyzeArtifacts(
                    promptPath: input.debugPrompt && input.storeArtifacts ? paths.artifactDir(runId: runId).appendingPathComponent("prompt.txt").path : nil,
                    analysisPath: analysisPath,
                    rawResponsePath: rawResponsePath,
                    stored: input.storeArtifacts
                )
            )
        } catch {
            try? memory.updateRunStatus(
                id: runId,
                status: "failed",
                completedAt: Date(),
                error: error.localizedDescription
            )
            throw AnalyzeRunFailure(runId: runId, phase: phase, underlying: error)
        }
    }

    private func validateImageForInlineUpload(_ url: URL) throws {
        let maxSize = 20 * 1024 * 1024
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attrs[.size] as? Int ?? 0
        guard fileSize <= maxSize else {
            throw GeminiError.imageTooLarge(fileSize)
        }
    }

    private func attachLogicalBoxes(_ analysis: DesignAnalysis, devicePixelRatio: Double) -> DesignAnalysis {
        guard devicePixelRatio > 0 else { return analysis }

        var updated = analysis
        updated.elements = updated.elements.map { element in
            var element = element
            if let px = element.bboxPx {
                element.bboxCss = BBoxPx(
                    x: Int((Double(px.x) / devicePixelRatio).rounded()),
                    y: Int((Double(px.y) / devicePixelRatio).rounded()),
                    width: Int((Double(px.width) / devicePixelRatio).rounded()),
                    height: Int((Double(px.height) / devicePixelRatio).rounded())
                )
            }
            return element
        }
        return updated
    }

    private func savePromptSnapshot(runId: String, system: String, user: String) async throws {
        let dir = paths.artifactDir(runId: runId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let content = "SYSTEM:\n\(system)\n\nUSER:\n\(user)"
        let url = dir.appendingPathComponent("prompt.txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func saveRawResponse(
        runId: String,
        screenName: String,
        raw: GeminiRawTextResponse,
        storeArtifact: Bool,
        artifactDate: Date,
        savedPath: inout String?
    ) async throws -> String {
        let evidenceId = StableID.evidence()
        let refURL = paths.refURL(evidenceId: evidenceId, date: artifactDate)
        let contentPath = storeArtifact ? refURL.path : "memory://not-stored/\(evidenceId)"

        let record: [String: AnyEncodable] = [
            "id": AnyEncodable(evidenceId),
            "run_id": AnyEncodable(runId),
            "project_id": AnyEncodable(context.projectId),
            "session_id": AnyEncodable(context.sessionId),
            "screen_name": AnyEncodable(screenName),
            "kind": AnyEncodable("geminiRawResponse"),
            "text": AnyEncodable(raw.text),
            "model": AnyEncodable(raw.model),
            "token_count": AnyEncodable(raw.tokenCount.map { "\($0.totalTokenCount ?? 0)" } ?? "unknown")
        ]

        if storeArtifact {
            let data = try JSON.encoder.encode(record)
            try FileManager.default.createDirectory(at: refURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: refURL)
            savedPath = refURL.path
        }

        try memory.insertEvidenceRecord(
            id: evidenceId,
            runId: runId,
            sessionId: context.sessionId,
            screenName: screenName,
            kind: "geminiRawResponse",
            contentPath: contentPath,
            summary: storeArtifact ? nil : raw.text.prefix(500).description
        )

        return evidenceId
    }

    private func saveAnalysis(runId: String, analysis: DesignAnalysis, storeArtifact: Bool) async throws -> String? {
        guard storeArtifact else { return nil }

        let dir = paths.artifactDir(runId: runId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("analysis.json")
        let data = try JSON.encoder.encode(analysis)
        try data.write(to: url)
        return url.path
    }

    private func repairJSON(rawText: String, model: String) async throws -> DesignAnalysis {
        let systemInstruction = "You are a JSON repair tool. The JSON below should match the DesignAnalysis schema. Fix it and return valid JSON only."
        let userPrompt = "Repair this JSON to match the DesignAnalysis schema. Return JSON only.\n\n\(rawText)"

        let response = try await gemini.analyzeText(
            model: model,
            systemInstruction: systemInstruction,
            userPrompt: userPrompt,
            responseSchema: GeminiJSONSchema.designAnalysis
        )

        do {
            return try JSON.decoder.decode(DesignAnalysis.self, from: response.data)
        } catch {
            throw GeminiError.invalidJSON("Repair attempt also failed: \(error)")
        }
    }
}

public struct AnalyzeRunFailure: Error, LocalizedError, Sendable {
    public let runId: String
    public let phase: String
    public let underlying: Error

    public init(runId: String, phase: String, underlying: Error) {
        self.runId = runId
        self.phase = phase
        self.underlying = underlying
    }

    public var errorDescription: String? {
        underlying.localizedDescription
    }
}

public struct AnalyzeResult: Codable, Sendable {
    public var ok: Bool
    public var runId: String
    public var projectId: String
    public var screen: String
    public var model: String
    public var analysis: DesignAnalysis
    public var memory: AnalyzeMemoryInfo
    public var artifacts: AnalyzeArtifacts
}

public struct AnalyzeMemoryInfo: Codable, Sendable {
    public var usedAtomIds: [String]
    public var writtenAtomIds: [String]
    public var sceneUpdated: Bool
    public var profileUpdated: Bool
}

public struct AnalyzeArtifacts: Codable, Sendable {
    public var promptPath: String?
    public var analysisPath: String?
    public var rawResponsePath: String?
    public var stored: Bool
}

public struct AnyEncodable: Encodable, Sendable {
    let value: any Encodable & Sendable

    public init(_ value: any Encodable & Sendable) {
        self.value = value
    }

    public func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}
