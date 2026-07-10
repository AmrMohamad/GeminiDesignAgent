import Foundation

/// Applies deterministic safety rules to model-suggested memory before persistence.
public enum MemoryWritePolicy {
    public static func validate(_ writes: [MemoryWrite], screenName: String?) -> [MemoryWrite] {
        writes.compactMap { write in
            let content = write.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, content.count <= 1_000 else { return nil }
            guard write.type != .userPreference else { return nil }
            var value = write
            value.content = content
            value.tags = Array(Array(Set(write.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty && $0.count <= 64 })).sorted().prefix(16))
            value.priority = min(100, max(0, value.priority))
            value.confidence = min(1, max(0, value.confidence))
            value.sceneName = value.sceneName ?? screenName
            if value.type == .implementationInstruction { value.scope = .screen }
            if value.scope == .global { value.scope = .screen }
            return value
        }
    }
}
