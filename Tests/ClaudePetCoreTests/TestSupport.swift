import Foundation
@testable import ClaudePetCore

enum TestSupport {
    /// Build a usage entry with explicit fields for deterministic tests.
    static func entry(id: String = UUID().uuidString,
                      at date: Date,
                      model: String = "claude-opus-4-8",
                      input: Int = 0, output: Int = 0,
                      cacheRead: Int = 0, cw5m: Int = 0, cw1h: Int = 0,
                      sidechain: Bool = false) -> UsageEntry {
        UsageEntry(messageID: id, timestamp: date, model: model,
                   family: ModelFamily(modelID: model),
                   inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
                   cacheWrite5mTokens: cw5m, cacheWrite1hTokens: cw1h, isSidechain: sidechain)
    }
}
