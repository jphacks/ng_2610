import Foundation

/// The Apple-signed distribution files ship with the app; no demo pairing or server is needed.
enum BundledShortcut: String, CaseIterable, Identifiable {
    case earthquake, tsunami
    case liveEarthquake = "live-earthquake"
    case liveTsunami = "live-tsunami"

    static let training: [Self] = [.earthquake, .tsunami]
    static let live: [Self] = [.liveEarthquake, .liveTsunami]

    var id: String { rawValue }
    var fileName: String { "nigeyo-\(rawValue)" }
    // File imports use the filename as the shortcut name. Keep test URLs consistent with it.
    var importName: String {
        switch self {
        case .earthquake: "nigeyo 地震"
        case .tsunami: "nigeyo 津波"
        case .liveEarthquake: "nigeyo 本番 地震"
        case .liveTsunami: "nigeyo 本番 津波"
        }
    }

    var notificationTitle: String {
        switch self {
        case .earthquake: "EARTHQUAKE_TEST"
        case .tsunami: "TSUNAMI_TEST"
        case .liveEarthquake: "EARTHQUAKE_ALERT"
        case .liveTsunami: "TSUNAMI_ALERT"
        }
    }

    func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: fileName, withExtension: "shortcut")
            ?? bundle.url(forResource: fileName, withExtension: "shortcut", subdirectory: "Shortcuts")
    }

    func exportURL(in bundle: Bundle = .main) throws -> URL {
        guard let source = bundledURL(in: bundle) else { throw CocoaError(.fileNoSuchFile) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NigeyoShortcuts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(importName).appendingPathExtension("shortcut")
        // Copy byte for byte: editing the signed workflow would invalidate the Apple signature.
        try FileManager.default.copyItem(at: source, to: target)
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
