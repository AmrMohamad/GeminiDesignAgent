import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct CompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare two screenshot files locally",
        discussion: """
        Examples:
          gda compare --before old.png --after new.png --json
        """
    )

    @Option(name: .long, help: "Before screenshot path")
    var before: String

    @Option(name: .long, help: "After screenshot path")
    var after: String

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let beforeURL = URL(fileURLWithPath: before)
            let afterURL = URL(fileURLWithPath: after)
            let beforeInfo = try ImageInfoReader.read(beforeURL)
            let afterInfo = try ImageInfoReader.read(afterURL)

            let data: [String: Any] = [
                "before": imageObject(beforeInfo, path: beforeURL.path),
                "after": imageObject(afterInfo, path: afterURL.path),
                "delta": [
                    "width_px": afterInfo.width - beforeInfo.width,
                    "height_px": afterInfo.height - beforeInfo.height,
                    "file_size_bytes": afterInfo.fileSize - beforeInfo.fileSize,
                    "same_dimensions": beforeInfo.width == afterInfo.width && beforeInfo.height == afterInfo.height,
                    "same_format": beforeInfo.mimeType == afterInfo.mimeType
                ],
                "warnings": warnings(before: beforeInfo, after: afterInfo)
            ]

            if json {
                CLIResponse.success(command: "compare", data: data)
            } else {
                print("Before: \(beforeInfo.width)x\(beforeInfo.height) \(beforeInfo.mimeType)")
                print("After:  \(afterInfo.width)x\(afterInfo.height) \(afterInfo.mimeType)")
                print("Delta:  \(afterInfo.width - beforeInfo.width)x\(afterInfo.height - beforeInfo.height)")
            }
        } catch {
            if json { CLIResponse.failure(command: "compare", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }

    private func imageObject(_ info: ImageInfo, path: String) -> [String: Any] {
        [
            "path": path,
            "width_px": info.width,
            "height_px": info.height,
            "mime_type": info.mimeType,
            "file_size_bytes": info.fileSize
        ]
    }

    private func warnings(before: ImageInfo, after: ImageInfo) -> [String] {
        var warnings: [String] = []
        if before.width != after.width || before.height != after.height {
            warnings.append("Screenshots have different dimensions; layout measurements may not be directly comparable.")
        }
        if before.mimeType != after.mimeType {
            warnings.append("Screenshots use different image formats.")
        }
        return warnings
    }
}
