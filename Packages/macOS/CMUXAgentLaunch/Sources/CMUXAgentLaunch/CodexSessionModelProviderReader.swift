import Foundation

/// Reads the model provider a Codex session was created with from its rollout.
///
/// Codex records the provider in the rollout's leading `session_meta` line and
/// resolves it again on `codex resume <id>`: a session created through
/// `sr codex` records `"subrouter"`, which a plain `codex resume` cannot resolve
/// unless the user's own `config.toml` defines that provider. The rollout is
/// therefore the session's own statement of how it must be resumed, independent
/// of whatever launch evidence a terminal host managed to capture.
///
/// The reader is bounded: it scans a fixed number of directory entries, reads
/// at most ``maximumMetadataBytes`` of one file, and only accepts a
/// `session_meta` whose `id` matches the requested session.
public struct CodexSessionModelProviderReader: Sendable {
    static let maximumScannedEntries = 50_000
    static let maximumMetadataBytes = 8 * 1024 * 1024

    /// Creates a stateless rollout reader.
    public init() {}

    /// Returns the `model_provider` recorded for `sessionID` under `codexHome`,
    /// or `nil` when the rollout cannot be found or does not record one.
    ///
    /// - Parameters:
    ///   - sessionID: The Codex session (thread) id.
    ///   - codexHome: The resolved Codex state directory (`CODEX_HOME`).
    public func modelProvider(sessionID: String, codexHome: String) -> String? {
        guard Self.isWellFormedSessionID(sessionID),
              let path = rolloutPath(sessionID: sessionID, codexHome: codexHome) else {
            return nil
        }
        return modelProvider(rolloutAtPath: path, sessionID: sessionID)
    }

    /// Returns the `model_provider` from the first line of the rollout at
    /// `path` when that line is the `session_meta` for `sessionID`.
    func modelProvider(rolloutAtPath path: String, sessionID: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while line.count < Self.maximumMetadataBytes {
            let remaining = Self.maximumMetadataBytes - line.count
            guard let chunk = try? handle.read(upToCount: min(64 * 1024, remaining)),
                  !chunk.isEmpty else {
                break
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[chunk.startIndex..<newline])
                return sessionMetaProvider(line, sessionID: sessionID)
            }
            line.append(chunk)
        }
        return sessionMetaProvider(line, sessionID: sessionID)
    }

    private func sessionMetaProvider(_ line: Data, sessionID: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              (payload["id"] as? String)?.lowercased() == sessionID.lowercased(),
              let provider = payload["model_provider"] as? String else {
            return nil
        }
        let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func rolloutPath(sessionID: String, codexHome: String) -> String? {
        let suffix = "-\(sessionID.lowercased()).jsonl"
        let fileManager = FileManager.default
        var scanned = 0
        for directory in ["sessions", "archived_sessions"] {
            let root = URL(fileURLWithPath: codexHome, isDirectory: true)
                .appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            while let item = enumerator.nextObject() as? URL {
                scanned += 1
                if scanned > Self.maximumScannedEntries { return nil }
                let name = item.lastPathComponent.lowercased()
                guard name.hasPrefix("rollout-"), name.hasSuffix(suffix) else { continue }
                if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    return item.path
                }
            }
        }
        return nil
    }

    /// Session ids are UUIDs; anything else is never used to build a lookup.
    static func isWellFormedSessionID(_ sessionID: String) -> Bool {
        UUID(uuidString: sessionID) != nil
    }
}
