import XCTest
@testable import GeminiDesignAgentCore

final class GeminiDesignSessionTests: XCTestCase {
    func testAnalyzeCompletesRunWritesMemoryAndSecondRunUsesMemory() async throws {
        let harness = try makeHarness()
        let imageURL = try makePNG(in: harness.tempDir)
        let fakeGemini = FakeGeminiClient(imageResults: [
            .success(try rawResponse(analysis: makeAnalysis(
                summary: "Home screen uses a gold primary button.",
                memoryWrites: [
                    MemoryWrite(
                        type: .designToken,
                        scope: .global,
                        priority: 90,
                        content: "Primary button uses gold color",
                        tags: ["button", "color"]
                    )
                ]
            ))),
            .success(try rawResponse(analysis: makeAnalysis(
                summary: "Product screen keeps the gold primary button.",
                memoryWrites: []
            )))
        ])

        let firstSession = GeminiDesignSession(
            context: harness.context,
            gemini: fakeGemini,
            memory: harness.store,
            paths: harness.paths
        )
        let first = try await firstSession.analyzeScreen(AnalyzeScreenInput(
            imageURL: imageURL,
            screenName: "Home",
            request: "gold button",
            debugPrompt: true
        ))

        XCTAssertEqual(first.memory.writtenAtomIds.count, 1)
        XCTAssertEqual(try runStatus(db: harness.db, id: first.runId), "completed")
        XCTAssertEqual(try evidenceScreenName(db: harness.db), "Home")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.artifacts.promptPath ?? ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.artifacts.analysisPath ?? ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.artifacts.rawResponsePath ?? ""))

        let secondSession = GeminiDesignSession(
            context: harness.context,
            gemini: fakeGemini,
            memory: harness.store,
            paths: harness.paths
        )
        let second = try await secondSession.analyzeScreen(AnalyzeScreenInput(
            imageURL: imageURL,
            screenName: "Product",
            request: "gold button"
        ))

        XCTAssertTrue(second.memory.usedAtomIds.contains(first.memory.writtenAtomIds[0]))
        XCTAssertEqual(try runStatus(db: harness.db, id: second.runId), "completed")
    }

    func testInvalidGeminiJSONTriggersOneRepairCall() async throws {
        let harness = try makeHarness()
        let imageURL = try makePNG(in: harness.tempDir)
        let fakeGemini = FakeGeminiClient(
            imageResults: [.success(GeminiRawTextResponse(text: "{ invalid", data: Data("{ invalid".utf8), model: "gemini-2.5-flash", tokenCount: nil))],
            textResults: [.success(try rawResponse(analysis: makeAnalysis(summary: "Repaired analysis.", memoryWrites: [])))]
        )

        let session = GeminiDesignSession(
            context: harness.context,
            gemini: fakeGemini,
            memory: harness.store,
            paths: harness.paths
        )

        let result = try await session.analyzeScreen(AnalyzeScreenInput(
            imageURL: imageURL,
            screenName: "Repair",
            request: "repair test"
        ))

        XCTAssertEqual(result.analysis.summary, "Repaired analysis.")
        XCTAssertEqual(fakeGemini.textCallCount, 1)
    }

    func testNoStoreSkipsArtifactFilesButKeepsMemoryWrites() async throws {
        let harness = try makeHarness()
        let imageURL = try makePNG(in: harness.tempDir)
        let fakeGemini = FakeGeminiClient(imageResults: [
            .success(try rawResponse(analysis: makeAnalysis(
                summary: "No-store run still writes memory.",
                memoryWrites: [
                    MemoryWrite(
                        type: .designToken,
                        scope: .global,
                        priority: 90,
                        content: "No-store primary button fact",
                        tags: ["button"]
                    )
                ]
            )))
        ])
        let session = GeminiDesignSession(
            context: harness.context,
            gemini: fakeGemini,
            memory: harness.store,
            paths: harness.paths
        )

        let result = try await session.analyzeScreen(AnalyzeScreenInput(
            imageURL: imageURL,
            screenName: "NoStore",
            request: "button",
            debugPrompt: true,
            storeArtifacts: false
        ))

        XCTAssertFalse(result.artifacts.stored)
        XCTAssertNil(result.artifacts.promptPath)
        XCTAssertNil(result.artifacts.analysisPath)
        XCTAssertNil(result.artifacts.rawResponsePath)
        XCTAssertEqual(result.memory.writtenAtomIds.count, 1)

        let recalled = try await harness.store.searchAtoms(MemoryQuery(text: "No-store primary", limit: 5))
        XCTAssertEqual(recalled.first?.atom.id, result.memory.writtenAtomIds.first)
    }

    func testFailureAfterRunStartMarksRunFailed() async throws {
        let harness = try makeHarness()
        let imageURL = try makePNG(in: harness.tempDir)
        let fakeGemini = FakeGeminiClient(imageResults: [.failure(GeminiError.timeout)])
        let session = GeminiDesignSession(
            context: harness.context,
            gemini: fakeGemini,
            memory: harness.store,
            paths: harness.paths
        )

        do {
            _ = try await session.analyzeScreen(AnalyzeScreenInput(
                imageURL: imageURL,
                screenName: "Failure",
                request: "fail"
            ))
            XCTFail("Expected analyzeScreen to throw")
        } catch {
            guard case GeminiError.timeout = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }

        XCTAssertEqual(try latestRunStatus(db: harness.db), "failed")
    }

    private struct Harness {
        var tempDir: URL
        var paths: ArtifactPaths
        var db: SQLiteDB
        var store: SQLiteMemoryStore
        var context: RuntimeContext
    }

    private final class FakeGeminiClient: GeminiDesignAnalyzing, @unchecked Sendable {
        private let lock = NSLock()
        private var imageResults: [Result<GeminiRawTextResponse, Error>]
        private var textResults: [Result<GeminiRawTextResponse, Error>]
        private(set) var textCallCount = 0

        init(
            imageResults: [Result<GeminiRawTextResponse, Error>],
            textResults: [Result<GeminiRawTextResponse, Error>] = []
        ) {
            self.imageResults = imageResults
            self.textResults = textResults
        }

        func analyzeImage(
            model: String,
            imageURL: URL,
            mimeType: String,
            systemInstruction: String,
            userPrompt: String,
            responseSchema: JSONValue
        ) async throws -> GeminiRawTextResponse {
            try nextImageResult().get()
        }

        func analyzeText(
            model: String,
            systemInstruction: String,
            userPrompt: String,
            responseSchema: JSONValue
        ) async throws -> GeminiRawTextResponse {
            try nextTextResult().get()
        }

        private func nextImageResult() throws -> Result<GeminiRawTextResponse, Error> {
            lock.lock()
            defer { lock.unlock() }
            guard !imageResults.isEmpty else { throw GeminiError.unexpectedResponse("No fake image response") }
            return imageResults.removeFirst()
        }

        private func nextTextResult() throws -> Result<GeminiRawTextResponse, Error> {
            lock.lock()
            defer { lock.unlock() }
            textCallCount += 1
            guard !textResults.isEmpty else { throw GeminiError.unexpectedResponse("No fake text response") }
            return textResults.removeFirst()
        }
    }

    private func makeHarness() throws -> Harness {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gda-session-tests-\(UUID().uuidString)")
        let paths = ArtifactPaths(projectDir: tempDir.appendingPathComponent("project"))
        try paths.ensureDirectories()
        let db = try SQLiteDB(path: paths.dbPath.path)
        try DatabaseMigrator.migrate(db: db)
        let context = RuntimeContext(projectId: "proj_session", projectName: "Session", projectDir: paths.rootDir.path)
        let store = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
        return Harness(tempDir: tempDir, paths: paths, db: db, store: store, context: context)
    }

    private func makePNG(in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.png")
        var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
        bytes += [0, 0, 0, 2, 0, 0, 0, 2]
        try Data(bytes).write(to: url)
        return url
    }

    private func makeAnalysis(summary: String, memoryWrites: [MemoryWrite]) -> DesignAnalysis {
        DesignAnalysis(
            summary: summary,
            tokens: DesignTokens(
                colors: [NamedColorToken(name: "primary", hex: "#D7A84F")],
                typography: [TypographyToken(name: "body", fontSizePx: 16)],
                spacingScalePx: [8, 12, 16],
                radiiPx: [12],
                shadows: []
            ),
            elements: [
                DesignElement(
                    id: "primary_cta",
                    type: .button,
                    label: "Primary CTA",
                    bbox1000: BBox1000(ymin: 100, xmin: 100, ymax: 300, xmax: 500)
                )
            ],
            hierarchy: [],
            components: [
                ComponentCandidate(
                    id: "component_button",
                    name: "primary_button",
                    description: "Gold primary button",
                    elementIds: ["primary_cta"],
                    confidence: 0.9
                )
            ],
            implementation: ImplementationGuidance(framework: "SwiftUI", layoutStrategy: "VStack", notes: ["Reuse primary button token"]),
            accessibility: [],
            warnings: [],
            memoryWrites: memoryWrites
        )
    }

    private func rawResponse(analysis: DesignAnalysis) throws -> GeminiRawTextResponse {
        let data = try JSON.encoder.encode(analysis)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        return GeminiRawTextResponse(text: text, data: data, model: "gemini-2.5-flash", tokenCount: nil)
    }

    private func runStatus(db: SQLiteDB, id: String) throws -> String? {
        let stmt = try db.prepare("SELECT status FROM runs WHERE id = ?")
        defer { stmt.finalize() }
        try stmt.bind(id, at: 1)
        guard try stmt.step() else { return nil }
        return stmt.columnText(0)
    }

    private func latestRunStatus(db: SQLiteDB) throws -> String? {
        let stmt = try db.prepare("SELECT status FROM runs ORDER BY started_at DESC LIMIT 1")
        defer { stmt.finalize() }
        guard try stmt.step() else { return nil }
        return stmt.columnText(0)
    }

    private func evidenceScreenName(db: SQLiteDB) throws -> String? {
        let stmt = try db.prepare("SELECT screen_name FROM evidence_records ORDER BY created_at DESC LIMIT 1")
        defer { stmt.finalize() }
        guard try stmt.step() else { return nil }
        return stmt.columnText(0)
    }
}
