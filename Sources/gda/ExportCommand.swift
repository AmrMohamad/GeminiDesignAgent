import Foundation
import ArgumentParser
import GeminiDesignAgentCore

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export curated memory to design-tool formats",
        discussion: """
        Examples:
          gda export --format figma-tokens --json
          gda export --format style-dictionary
          gda export --format tailwind
        """
    )

    @Option(name: .long, help: "Project directory path")
    var projectDir: String = ".gda"

    @Option(name: .long, help: "Export format: figma-tokens, style-dictionary, tailwind, json")
    var format: String = "json"

    @Flag(name: .long, help: "Output JSON only")
    var json: Bool = false

    func run() async throws {
        if json { Logger.setJSONMode(true) }

        do {
            let (context, paths, db) = try CLIUtils.loadOrInitProject(projectDir: projectDir)
            let memory = try SQLiteMemoryStore(db: db, projectId: context.projectId, recordsDir: paths.recordsDir)
            let profile = try await memory.getProjectProfile()
            let atoms = try memory.activeAtoms()
            let content = try render(format: format, profile: profile, atoms: atoms)

            if json {
                CLIResponse.success(
                    command: "export",
                    data: [
                        "format": format,
                        "content": content,
                        "atom_count": atoms.count,
                        "profile_used": profile != nil
                    ]
                )
            } else {
                print(content)
            }
        } catch {
            if json { CLIResponse.failure(command: "export", error: error) } else { print("Error: \(error.localizedDescription)") }
            throw ExitCode(1)
        }
    }

    private func render(format: String, profile: ProjectProfile?, atoms: [MemoryAtom]) throws -> String {
        switch format {
        case "json":
            let object: [String: Any] = [
                "profile": try profile.map { try CLIResponse.object(from: $0) } ?? NSNull(),
                "atoms": try CLIResponse.object(from: atoms)
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        case "figma-tokens", "style-dictionary":
            let object = designTokenObject(profile: profile)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        case "tailwind":
            return tailwindConfig(profile: profile)
        default:
            throw CLIError(
                code: "UNSUPPORTED_EXPORT_FORMAT",
                title: "Unsupported export format",
                message: "Unsupported export format: \(format)",
                resolution: "Use one of: json, figma-tokens, style-dictionary, tailwind.",
                retryable: false
            )
        }
    }

    private func designTokenObject(profile: ProjectProfile?) -> [String: Any] {
        guard let profile else { return ["global": [:]] }
        var colors: [String: Any] = [:]
        for color in profile.brandColors {
            colors[safeTokenName(color.name)] = ["value": color.hex, "type": "color"]
        }
        var spacing: [String: Any] = [:]
        for value in profile.spacingScalePx {
            spacing["space_\(value)"] = ["value": "\(value)px", "type": "dimension"]
        }
        var radii: [String: Any] = [:]
        for value in profile.radiiPx {
            radii["radius_\(value)"] = ["value": "\(value)px", "type": "dimension"]
        }
        return ["global": ["color": colors, "spacing": spacing, "radius": radii]]
    }

    private func tailwindConfig(profile: ProjectProfile?) -> String {
        guard let profile else {
            return "module.exports = { theme: { extend: {} } }"
        }
        let colors = profile.brandColors.map { "        \(safeTokenName($0.name)): '\($0.hex)'" }.joined(separator: ",\n")
        let spacing = profile.spacingScalePx.map { "        '\($0)': '\($0)px'" }.joined(separator: ",\n")
        let radii = profile.radiiPx.map { "        '\($0)': '\($0)px'" }.joined(separator: ",\n")
        return """
        module.exports = {
          theme: {
            extend: {
              colors: {
        \(colors)
              },
              spacing: {
        \(spacing)
              },
              borderRadius: {
        \(radii)
              }
            }
          }
        }
        """
    }

    private func safeTokenName(_ name: String) -> String {
        let cleaned = name.lowercased().replacingOccurrences(of: "[^a-z0-9_\\-]+", with: "_", options: .regularExpression)
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_-")).isEmpty ? "token" : cleaned
    }
}
