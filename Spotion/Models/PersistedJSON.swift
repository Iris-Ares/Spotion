import Foundation

/// One versioned JSON sidecar for state Spotion owns (pins, aliases, hidden
/// sessions, exclusions…). It lives beside the scan cache but is independent
/// of it, so cache resets and schema bumps never lose user intent.
/// Writes are atomic; with a mirror URL the mirror is written first, so a torn
/// or corrupted primary can be recovered on the next load.
struct PersistedJSON<Payload: Codable & Sendable>: Sendable {
    enum Loaded: Sendable {
        /// No file on disk yet.
        case empty
        /// Primary decoded normally.
        case loaded(Payload)
        /// Primary unreadable, mirror decoded (primary has been rewritten).
        case recovered(Payload)
        /// Nothing decodable — the caller decides whether to fail open or closed.
        case unreadable
    }

    private struct Envelope: Codable {
        var version: Int
        var payload: Payload
    }

    let url: URL
    let mirrorURL: URL?
    let version: Int

    init(url: URL, mirrorURL: URL? = nil, version: Int) {
        self.url = url
        self.mirrorURL = mirrorURL
        self.version = version
    }

    func load() -> Loaded {
        let manager = FileManager.default
        let primaryExists = manager.fileExists(atPath: url.path)
        let mirrorExists = mirrorURL.map { manager.fileExists(atPath: $0.path) } ?? false
        guard primaryExists || mirrorExists else { return .empty }

        if let payload = decode(url) {
            // Heal a missing or stale mirror while the primary is known good.
            if let mirrorURL { try? write(payload, to: mirrorURL) }
            return .loaded(payload)
        }
        if let mirrorURL, let payload = decode(mirrorURL) {
            try? write(payload, to: url)
            return .recovered(payload)
        }
        return .unreadable
    }

    func write(_ payload: Payload) throws {
        if let mirrorURL { try write(payload, to: mirrorURL) }
        try write(payload, to: url)
    }

    private func decode(_ url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == version else { return nil }
        return envelope.payload
    }

    private func write(_ payload: Payload, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Envelope(version: version, payload: payload)).write(to: url, options: .atomic)
    }
}
