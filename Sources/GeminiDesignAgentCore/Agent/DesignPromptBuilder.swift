import Foundation

public struct DesignPromptBuilder {
    public static let systemPrompt = """
    You are a senior UI engineer and Figma-to-code design measurement agent.

    Return only valid JSON matching the provided schema.

    You analyze UI screenshots and extract:
    - canvas size
    - visual hierarchy
    - UI elements
    - bounding boxes
    - spacing
    - colors
    - typography guesses
    - border radii
    - shadows
    - reusable components
    - development-ready CSS/layout hints
    - memory updates that help future design analysis

    Rules:
    - Use bbox1000 as [ymin, xmin, ymax, xmax], normalized 0..1000.
    - Do not invent exact font family unless visibly obvious.
    - Mark estimated values with confidence.
    - Prefer reusable component names like primary_button, product_card, nav_bar.
    - Use the provided design memory, but do not blindly copy it if the image contradicts it.
    - If the new screenshot changes a design rule, add a memory write that supersedes the old pattern.
    """

    public static func build(
        screenName: String,
        request: String,
        imageInfo: ImageInfo,
        memory: MemoryInjection
    ) -> (system: String, user: String) {
        var userPromptParts: [String] = []

        userPromptParts.append("Task:")
        userPromptParts.append("Analyze this Figma-exported screenshot for development-ready implementation.")
        userPromptParts.append("")
        userPromptParts.append("Screen:")
        userPromptParts.append(screenName)
        userPromptParts.append("")
        userPromptParts.append("Actual image size:")
        userPromptParts.append("\(imageInfo.width) x \(imageInfo.height) px")
        userPromptParts.append("")
        userPromptParts.append("User request:")
        userPromptParts.append(request)

        if let profile = memory.projectProfile {
            userPromptParts.append("")
            userPromptParts.append("Project design profile:")
            userPromptParts.append("<profile>")
            let profileJSON: String
            if let data = try? JSON.compactEncoder.encode(profile),
               let json = String(data: data, encoding: .utf8) {
                profileJSON = json
            } else {
                profileJSON = "error encoding profile"
            }
            userPromptParts.append(profileJSON)
            userPromptParts.append("</profile>")
        }

        if let scene = memory.sceneBlock {
            userPromptParts.append("")
            userPromptParts.append("Relevant scene memory:")
            userPromptParts.append("<scene>")
            userPromptParts.append("Name: \(scene.name)")
            userPromptParts.append("Summary: \(scene.summary)")
            if !scene.keyComponents.isEmpty {
                userPromptParts.append("Components: \(scene.keyComponents.joined(separator: ", "))")
            }
            userPromptParts.append("</scene>")
        }

        if !memory.atoms.isEmpty {
            userPromptParts.append("")
            userPromptParts.append("Memory atoms recalled:")
            for result in memory.atoms {
                userPromptParts.append("* [\(result.atom.id)] (\(result.atom.type.rawValue)/\(result.atom.scope.rawValue), priority: \(result.atom.priority)) \(result.atom.content)")
            }
        }

        if !memory.canvas.isEmpty {
            userPromptParts.append("")
            userPromptParts.append("Symbolic design canvas:")
            userPromptParts.append("```mermaid")
            userPromptParts.append(memory.canvas)
            userPromptParts.append("```")
        }

        userPromptParts.append("")
        userPromptParts.append("Return DesignAnalysis JSON only.")

        return (systemPrompt, userPromptParts.joined(separator: "\n"))
    }
}
