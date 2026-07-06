import Foundation

public struct AnalyzeScreenInput: Sendable {
    public var imageURL: URL
    public var screenName: String
    public var request: String
    public var model: String
    public var memoryLimit: Int

    public init(
        imageURL: URL,
        screenName: String,
        request: String = "Extract layout, spacing, typography, colors, reusable components, and development-ready implementation values.",
        model: String = "gemini-2.5-flash",
        memoryLimit: Int = 8
    ) {
        self.imageURL = imageURL
        self.screenName = screenName
        self.request = request
        self.model = model
        self.memoryLimit = memoryLimit
    }
}

public actor GeminiDesignSession {
    private let context: RuntimeContext
    private let gemini: GeminiVisionClient
    private let memory: DesignMemoryStore
    private let paths: ArtifactPaths

    public init(
        context: RuntimeContext,
        gemini: GeminiVisionClient,
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
        let imageInfo = try ImageInfoReader.read(input.imageURL)
        let startedAt = Date()

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

        let injection = try await MemoryInjectionBuilder(memory: memory).build(
            screenName: input.screenName,
            request: input.request,
            limit: input.memoryLimit
        )

        let prompt = DesignPromptBuilder.build(
            screenName: input.screenName,
            request: input.request,
            imageInfo: imageInfo,
            memory: injection
        )

        try await savePromptSnapshot(runId: runId, system: prompt.system, user: prompt.user)

        let raw = try await gemini.analyzeImage(
            model: input.model,
            imageURL: input.imageURL,
            mimeType: imageInfo.mimeType,
            systemInstruction: prompt.system,
            userPrompt: prompt.user,
            responseSchema: GeminiJSONSchema.designAnalysis
        )

        let evidenceId = try await saveRawResponse(runId: runId, raw: raw)

        var analysis: DesignAnalysis
        do {
            analysis = try JSON.decoder.decode(DesignAnalysis.self, from: raw.data)
        } catch {
            Logger.warn("Gemini JSON decode failed, attempting repair: \(error)")
            let repaired = try await repairJSON(rawText: raw.text, model: input.model)
            analysis = repaired
        }

        analysis = DesignAnalysisPostProcessor.fillPixelBoxes(
            analysis,
            imageWidth: imageInfo.width,
            imageHeight: imageInfo.height
        )

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
            mimeType: imageInfo.mimeType
        )

        try await saveAnalysis(runId: runId, analysis: analysis)

        let writtenAtomIds = try await MemoryWriter(store: memory).applyWrites(
            analysis.memoryWrites,
            sourceEvidenceIds: [evidenceId],
            projectId: context.projectId,
            screenName: input.screenName
        )

        let compactor = MemoryCompactor(store: memory, projectId: context.projectId)
        let compactionResult = try await compactor.updateSceneAndProfileFastPath(
            from: analysis,
            screenName: input.screenName,
            runId: runId,
            evidenceId: evidenceId
        )

        try memory.insertRun(
            id: runId,
            sessionId: context.sessionId,
            screenName: input.screenName,
            imagePath: input.imageURL.path,
            model: input.model,
            request: input.request,
            status: "completed",
            startedAt: startedAt,
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
                analysisPath: paths.artifactDir(runId: runId).appendingPathComponent("analysis.json").path,
                rawResponsePath: paths.refsDir.appendingPathComponent("\(evidenceId).json").path
            )
        )
    }

    private func validateImageForInlineUpload(_ url: URL) throws {
        let maxSize = 20 * 1024 * 1024
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attrs[.size] as? Int ?? 0
        guard fileSize <= maxSize else {
            throw GeminiError.imageTooLarge(fileSize)
        }
    }

    private func savePromptSnapshot(runId: String, system: String, user: String) async throws {
        let dir = paths.artifactDir(runId: runId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let content = "SYSTEM:\n\(system)\n\nUSER:\n\(user)"
        let url = dir.appendingPathComponent("prompt.txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func saveRawResponse(runId: String, raw: GeminiRawTextResponse) async throws -> String {
        let evidenceId = StableID.evidence()
        let refURL = paths.refsDir.appendingPathComponent("\(evidenceId).json")

        let record: [String: AnyEncodable] = [
            "id": AnyEncodable(evidenceId),
            "run_id": AnyEncodable(runId),
            "project_id": AnyEncodable(context.projectId),
            "session_id": AnyEncodable(context.sessionId),
            "screen_name": AnyEncodable(context.screenName ?? ""),
            "kind": AnyEncodable("geminiRawResponse"),
            "text": AnyEncodable(raw.text),
            "model": AnyEncodable(raw.model),
            "token_count": AnyEncodable(raw.tokenCount.map { "\($0.totalTokenCount ?? 0)" } ?? "unknown")
        ]

        let data = try JSON.encoder.encode(record)
        try data.write(to: refURL)

        try memory.insertEvidenceRecord(
            id: evidenceId,
            runId: runId,
            sessionId: context.sessionId,
            screenName: context.screenName,
            kind: "geminiRawResponse",
            contentPath: refURL.path,
            summary: nil
        )

        return evidenceId
    }

    private func saveAnalysis(runId: String, analysis: DesignAnalysis) async throws {
        let dir = paths.artifactDir(runId: runId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("analysis.json")
        let data = try JSON.encoder.encode(analysis)
        try data.write(to: url)
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
    public var analysisPath: String
    public var rawResponsePath: String
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
