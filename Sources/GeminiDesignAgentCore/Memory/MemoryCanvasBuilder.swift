import Foundation

public struct MemoryCanvasBuilder {
    public static func build(
        profile: ProjectProfile?,
        scene: SceneBlock?,
        topAtoms: [MemoryAtom]
    ) -> String {
        var lines: [String] = []
        lines.append("graph TD")

        if let profile = profile {
            let escaped = escapeMermaid(truncate(profile.styleSummary, maxLen: 80))
            lines.append("  P[\"project_style<br/>\(escaped)<br/>node:profile\"]")

            for color in profile.brandColors.prefix(5) {
                let label = escapeMermaid("\(color.name) = \(color.hex)")
                lines.append("  C\(color.name.hashValue & 0xFF)[\"\(label)<br/>node:mem_color\"]")
                lines.append("  P --> C\(color.name.hashValue & 0xFF)")
            }

            for (i, atom) in topAtoms.prefix(12).enumerated() {
                let label = escapeMermaid(truncate(atom.content, maxLen: 60))
                lines.append("  A\(i)[\"\(label)<br/>node:\(atom.id)\"]")
                lines.append("  P --> A\(i)")
            }
        }

        if let scene = scene {
            let label = escapeMermaid(truncate(scene.summary, maxLen: 60))
            lines.append("  S[\"\(scene.name)<br/>\(label)<br/>node:\(scene.id)\"]")
        }

        return lines.joined(separator: "\n")
    }

    private static func escapeMermaid(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func truncate(_ text: String, maxLen: Int) -> String {
        if text.count <= maxLen { return text }
        return String(text.prefix(maxLen)) + "..."
    }
}
