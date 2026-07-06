import Foundation

public enum StableID {
    public static func run() -> String {
        "run_\(uuid().prefix(12))"
    }

    public static func evidence() -> String {
        "evi_\(uuid().prefix(12))"
    }

    public static func memory() -> String {
        "mem_\(uuid().prefix(12))"
    }

    public static func scene() -> String {
        "scene_\(uuid().prefix(12))"
    }

    public static func project() -> String {
        "proj_\(uuid().prefix(12))"
    }

    public static func element() -> String {
        "el_\(uuid().prefix(12))"
    }

    private static func uuid() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
