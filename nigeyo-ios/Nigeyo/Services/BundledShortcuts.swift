import Foundation

/// The Apple-signed distribution files ship with the app; no demo pairing or server is needed.
enum BundledShortcut: String, CaseIterable, Identifiable {
    case earthquake, tsunami

    var id: String { rawValue }
    var fileName: String { "nigeyo-\(rawValue)" }
    // File imports use the filename as the shortcut name. Keep test URLs consistent with it.
    var importName: String { self == .earthquake ? "nigeyo 地震" : "nigeyo 津波" }
    var notificationTitle: String { self == .earthquake ? "EARTHQUAKE_TEST" : "TSUNAMI_TEST" }

    func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: fileName, withExtension: "shortcut")
            ?? bundle.url(forResource: fileName, withExtension: "shortcut", subdirectory: "Shortcuts")
    }

    func exportURL(in bundle: Bundle = .main) throws -> URL {
        guard let source = bundledURL(in: bundle) else { throw CocoaError(.fileNoSuchFile) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NigeyoShortcuts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(importName).appendingPathExtension("shortcut")
        try? FileManager.default.removeItem(at: target) // stale copies collide on case-insensitive APFS
        // Copy byte for byte: editing the signed workflow would invalidate the Apple signature.
        try Data(contentsOf: source).write(to: target, options: .atomic)
        return target
    }

    var runURL: URL {
        var parts = URLComponents()
        parts.scheme = "shortcuts"
        parts.host = "run-shortcut"
        parts.queryItems = [URLQueryItem(name: "name", value: importName)]
        return parts.url!
    }
}

/// User-confirmed progress, not an assertion that iOS has installed or enabled anything.
struct ShortcutPreparation: Codable, Equatable {
    var earthquakeAdded = false
    var tsunamiAdded = false
    var automationsEnabled = false
    var earthquakeTested = false
    var tsunamiTested = false

    var bothAdded: Bool { earthquakeAdded && tsunamiAdded }
    var complete: Bool { bothAdded && automationsEnabled && earthquakeTested && tsunamiTested }
}
