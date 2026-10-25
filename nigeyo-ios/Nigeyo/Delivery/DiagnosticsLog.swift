import Foundation

/// Last 100 device-side events (receive / save / schedule / screen return), copyable from Settings.
/// Never records tokens, full pairing URLs, addresses or coordinates (spec §19).
actor DiagnosticsLog {
    struct Entry: Codable, Sendable {
        var at: Date
        var message: String
    }

    static let limit = 100
    private let url: URL
    private var entries: [Entry]

    init(url: URL? = nil) {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        self.url = url ?? dir.appendingPathComponent("diagnostics.json")
        entries = (try? JSONDecoder.nigeyo.decode([Entry].self, from: Data(contentsOf: self.url))) ?? []
    }

    func record(_ message: String) {
        entries.append(Entry(at: Date(), message: message))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        if let data = try? JSONEncoder.nigeyo.encode(entries) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func text() -> String {
        entries.map { "\(ISO8601.string($0.at)) \($0.message)" }.joined(separator: "\n")
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: url)
    }
}
