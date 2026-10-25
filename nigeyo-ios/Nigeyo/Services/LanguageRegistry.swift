import CryptoKit
import Foundation
import SwiftUI

struct LanguagePackage: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var packageVersion: Int
    var languageId: LanguageID
    var displayName: String
    var nativeName: String
    var direction: String
    var strings: [String: String]
}

struct LanguageInfo: Identifiable, Equatable, Sendable {
    var id: LanguageID
    var nativeName: String
    var displayName: String
    var packageVersion: Int
}

/// Typed placeholders from contracts/required-string-keys.json.
struct RequiredKeys: Decodable, Sendable {
    var keys: [String: [String: String]]

    static func bundled(_ bundle: Bundle = .main) -> RequiredKeys {
        guard let url = bundle.url(forResource: "required-string-keys", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RequiredKeys.self, from: data) else {
            preconditionFailure("required-string-keys.json missing from bundle")
        }
        return decoded
    }
}

enum LanguageValidation {
    static func placeholders(in s: String) -> [String] {
        let regex = /\{([A-Za-z]+)\}/
        return s.matches(of: regex).map { String($0.output.1) }.sorted()
    }

    /// Whole-package acceptance: any missing/empty key or placeholder drift rejects the package.
    static func problems(_ pkg: LanguagePackage, required: RequiredKeys) -> [String] {
        var errors: [String] = []
        if pkg.schemaVersion != 1 { errors.append("schemaVersion") }
        if pkg.packageVersion < 1 { errors.append("packageVersion") }
        if !pkg.languageId.isWellFormed { errors.append("languageId") }
        if pkg.nativeName.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("nativeName") }
        if !["ltr", "rtl"].contains(pkg.direction) { errors.append("direction") }
        for (key, types) in required.keys {
            guard let v = pkg.strings[key] else { errors.append("missing:\(key)"); continue }
            if v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("empty:\(key)") }
            if placeholders(in: v) != types.keys.sorted() { errors.append("placeholders:\(key)") }
        }
        return errors
    }
}

/// Bundled packages + verified cache in Application Support/Languages. No language enum,
/// no switch on language: adding a valid JSON adds a language (spec §12).
actor LanguageRegistry {
    private let bundle: Bundle
    private let cacheDirectory: URL
    private let required: RequiredKeys
    private var packages: [LanguageID: LanguagePackage] = [:]
    private(set) var diagnostics: [String] = []

    init(bundle: Bundle = .main, cacheDirectory: URL? = nil, required: RequiredKeys? = nil) {
        self.bundle = bundle
        self.required = required ?? RequiredKeys.bundled(bundle)
        self.cacheDirectory = cacheDirectory ?? ((try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("Languages", isDirectory: true)
    }

    func load() {
        packages = [:]
        let skip: Set<String> = ["cards", "evacuation-sites", "required-string-keys", "manifest"]
        let bundled = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            + (bundle.urls(forResourcesWithExtension: "json", subdirectory: "Languages") ?? [])
        for url in bundled where !skip.contains(url.deletingPathExtension().lastPathComponent) {
            register(url: url, origin: "bundle")
        }
        let cached = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in cached where url.pathExtension == "json" {
            register(url: url, origin: "cache")
        }
    }

    private func register(url: URL, origin: String) {
        guard let data = try? Data(contentsOf: url), let pkg = try? JSONDecoder().decode(LanguagePackage.self, from: data) else { return }
        let problems = LanguageValidation.problems(pkg, required: required)
        guard problems.isEmpty else {
            diagnostics.append("\(origin) \(url.lastPathComponent) rejected: \(problems.prefix(3).joined(separator: ","))")
            return
        }
        if let existing = packages[pkg.languageId], existing.packageVersion >= pkg.packageVersion { return }
        packages[pkg.languageId] = pkg
    }

    func available() -> [LanguageInfo] {
        packages.values
            .map { LanguageInfo(id: $0.languageId, nativeName: $0.nativeName, displayName: $0.displayName, packageVersion: $0.packageVersion) }
            .sorted { ($0.id == .english ? 0 : 1, $0.id.rawValue) < ($1.id == .english ? 0 : 1, $1.id.rawValue) }
    }

    /// Unknown languages normalize to English.
    func package(for id: LanguageID) -> LanguagePackage? {
        packages[id] ?? packages[.english]
    }

    func snapshot(for id: LanguageID) -> LanguageSnapshot? {
        guard let pkg = package(for: id) else { return nil }
        return LanguageSnapshot(languageId: pkg.languageId, packageVersion: pkg.packageVersion, strings: pkg.strings, direction: pkg.direction)
    }

    func validate(_ data: Data) -> Result<LanguagePackage, LanguageUpdateError> {
        guard let pkg = try? JSONDecoder().decode(LanguagePackage.self, from: data) else { return .failure(.invalidPackage("decode")) }
        let problems = LanguageValidation.problems(pkg, required: required)
        return problems.isEmpty ? .success(pkg) : .failure(.invalidPackage(problems.first ?? "invalid"))
    }

    /// Atomically stores a verified package and registers it; the previous good version stays on failure.
    func install(_ data: Data, expectedSHA256: String) throws -> LanguagePackage {
        guard SHA256.hash(data: data).hexString == expectedSHA256.lowercased() else { throw LanguageUpdateError.checksumMismatch }
        let pkg = try validate(data).get()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: cacheDirectory.appendingPathComponent("\(pkg.languageId.rawValue).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if (packages[pkg.languageId]?.packageVersion ?? 0) < pkg.packageVersion { packages[pkg.languageId] = pkg }
        return pkg
    }

    func deleteCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        load()
    }
}

extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// Lookup with typed placeholder substitution. Missing keys fall back to the key itself
/// (never happens for validated packages).
struct Strings: Sendable, Equatable {
    var languageId: LanguageID
    var table: [String: String]
    var isRTL: Bool

    init(languageId: LanguageID, table: [String: String], isRTL: Bool = false) {
        self.languageId = languageId
        self.table = table
        self.isRTL = isRTL
    }

    init(snapshot: LanguageSnapshot) {
        self.init(languageId: snapshot.languageId, table: snapshot.strings, isRTL: snapshot.direction == "rtl")
    }

    var direction: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }

    static let empty = Strings(languageId: .english, table: [:])

    subscript(_ key: String) -> String { table[key] ?? key }

    func callAsFunction(_ key: String, _ args: [String: String] = [:]) -> String {
        var s = self[key]
        for (k, v) in args { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }

    var locale: Locale { Locale(identifier: languageId.rawValue) }

    func distance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", meters / 1000)
    }

    func scale(_ value: Int?) -> String {
        guard let value else { return self["common.unknown"] }
        return table["scale.\(value)"] ?? self["common.unknown"]
    }

    /// Formats a JST ISO string in the session's language (time zone Asia/Tokyo, original instant).
    func dateTime(_ iso: String) -> String {
        guard let d = ISO8601.parse(iso) else { return iso }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        style.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return d.formatted(style)
    }
}

enum LanguageUpdateError: Error, Equatable {
    case noOrigin, crossOrigin, tooLarge, http(Int), checksumMismatch, invalidPackage(String), busy, network
}
