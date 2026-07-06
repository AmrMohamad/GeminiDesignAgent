import Foundation

public enum MemoryRanking {
    public static func rank(
        bm25Score: Double,
        atom: MemoryAtom,
        query: MemoryQuery,
        now: Date = Date()
    ) -> Double {
        var score = bm25Score

        score += Double(atom.priority) * 0.1

        if let screenName = query.screenName, atom.sceneName == screenName {
            score += 5.0
        }

        if let componentName = query.componentName, atom.componentName == componentName {
            score += 5.0
        }

        let ageInDays = now.timeIntervalSince(atom.createdAt) / 86400.0
        if ageInDays < 7 {
            score += max(0, 3.0 - ageInDays * 0.4)
        }

        return score
    }
}
