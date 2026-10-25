import Foundation

/// "言語パッケージを更新": static JSON from the configured HTTPS origin only, never during guidance.
/// Same origin (redirects included), ≤256KB, SHA-256 + full key validation (spec §12.2).
struct LanguageUpdater {
    static let maxBytes = 256 * 1024

    struct ManifestEntry: Decodable {
        var languageId: LanguageID
        var packageVersion: Int
        var file: String
        var sha256: String
    }

    struct Manifest: Decodable {
        var languages: [ManifestEntry]
    }

    struct Outcome: Equatable {
        var added: Int
        var updated: Int
        var rejected: [String]
    }

    let registry: LanguageRegistry

    private final class SameOriginDelegate: NSObject, URLSessionTaskDelegate {
        let origin: URL
        init(origin: URL) { self.origin = origin }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, url.scheme == "https", url.host == origin.host, url.port == origin.port else { return nil }
            return request
        }
    }

    private func fetch(_ url: URL, origin: URL) async throws -> Data {
        let delegate = SameOriginDelegate(origin: origin)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { throw LanguageUpdateError.network }
        guard http.url?.host == origin.host else { throw LanguageUpdateError.crossOrigin }
        guard http.statusCode == 200 else { throw LanguageUpdateError.http(http.statusCode) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxBytes { throw LanguageUpdateError.tooLarge }
        }
        return data
    }

    static func isSafeFileName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9-]{2,35}\.json$"#, options: .regularExpression) != nil
    }

    func update(origin: URL) async throws -> Outcome {
        guard origin.scheme == "https", origin.host != nil else { throw LanguageUpdateError.noOrigin }
        let manifestData = try await fetch(origin.appending(path: "public/languages/manifest.json"), origin: origin)
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else { throw LanguageUpdateError.invalidPackage("manifest") }
        let installed = Dictionary(uniqueKeysWithValues: await registry.available().map { ($0.id, $0.packageVersion) })
        var outcome = Outcome(added: 0, updated: 0, rejected: [])
        for entry in manifest.languages {
            let current = installed[entry.languageId]
            if let current, current >= entry.packageVersion { continue }
            guard Self.isSafeFileName(entry.file), entry.file == "\(entry.languageId.rawValue).json" else {
                outcome.rejected.append(entry.languageId.rawValue)
                continue
            }
            do {
                let data = try await fetch(origin.appending(path: "public/languages/\(entry.file)"), origin: origin)
                let pkg = try await registry.install(data, expectedSHA256: entry.sha256)
                guard pkg.languageId == entry.languageId, pkg.packageVersion == entry.packageVersion else { throw LanguageUpdateError.invalidPackage("manifest-mismatch") }
                if current == nil { outcome.added += 1 } else { outcome.updated += 1 }
            } catch {
                outcome.rejected.append(entry.languageId.rawValue)
            }
        }
        return outcome
    }
}
