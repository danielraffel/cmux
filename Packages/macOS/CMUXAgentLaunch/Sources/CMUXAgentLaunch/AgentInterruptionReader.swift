import Foundation

/// What a session was doing when its process last stopped, read from the
/// agent's own transcript.
public struct AgentInterruption: Equatable, Sendable, Codable {
    public enum State: String, Equatable, Sendable, Codable {
        /// The last turn finished, or the user stopped it. Nothing to continue.
        case idle
        /// A turn was running (or ended on an error) with no tool call open.
        case midTurn
        /// A tool call was issued and its result was never recorded, so its
        /// effect is unknown.
        case midToolCall
    }

    public var state: State
    /// Timestamp of the last transcript entry: the latest moment the session
    /// is known to have been alive.
    public var interruptedAt: Date?
    /// Name of the last tool call that has no recorded result.
    public var pendingToolName: String?
    /// Identifies this exact interruption. A session that resumed and wrote
    /// anything since gets a different fingerprint.
    public var fingerprint: String

    public init(state: State, interruptedAt: Date?, pendingToolName: String?, fingerprint: String) {
        self.state = state
        self.interruptedAt = interruptedAt
        self.pendingToolName = pendingToolName
        self.fingerprint = fingerprint
    }
}

/// Reads the tail of a Claude transcript or a Codex rollout and classifies how
/// the session stopped. Pure over the bytes it reads; the reads are bounded to
/// ``maximumTailBytes`` from the end of the file.
public struct AgentInterruptionReader: Sendable {
    static let maximumTailBytes = 8 * 1024 * 1024

    public init() {}

    /// Classifies the transcript at `path` for an agent `kind` (`claude` or `codex`).
    public func interruption(kind: String, transcriptPath path: String) -> AgentInterruption? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(Self.maximumTailBytes) ? size - UInt64(Self.maximumTailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty {
            // The first line of a tail window is usually a fragment.
            lines.removeFirst()
        }
        let objects = lines.compactMap { line -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        }
        return interruption(kind: kind, entries: objects, fileSize: size)
    }

    /// Classifies already-decoded transcript entries, oldest first.
    public func interruption(kind: String, entries: [[String: Any]], fileSize: UInt64) -> AgentInterruption? {
        switch kind.lowercased() {
        case "claude":
            return claudeInterruption(entries, fileSize: fileSize)
        case "codex":
            return codexInterruption(entries, fileSize: fileSize)
        default:
            return nil
        }
    }

    // MARK: Claude

    private static let claudeTurnEndSubtypes: Set<String> = ["turn_duration", "stop_hook_summary"]
    private static let claudeUserInterruptMarkers = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    ]

    private func claudeInterruption(_ entries: [[String: Any]], fileSize: UInt64) -> AgentInterruption? {
        var turnOpen = false
        var pending: [(id: String, name: String)] = []
        var lastTimestamp: String?
        var sawConversation = false
        for entry in entries {
            if let timestamp = entry["timestamp"] as? String { lastTimestamp = timestamp }
            if entry["isSidechain"] as? Bool == true { continue }
            let type = entry["type"] as? String
            let content = (entry["message"] as? [String: Any])?["content"]
            switch type {
            case "user":
                sawConversation = true
                if entry["isMeta"] as? Bool == true { continue }
                let blocks = content as? [[String: Any]] ?? []
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                if !results.isEmpty {
                    let ids = Set(results.compactMap { $0["tool_use_id"] as? String })
                    pending.removeAll { ids.contains($0.id) }
                    turnOpen = true
                    if claudeText(content).contains(where: isClaudeUserInterrupt) {
                        turnOpen = false
                        pending.removeAll()
                    }
                    continue
                }
                if claudeText(content).contains(where: isClaudeUserInterrupt) {
                    turnOpen = false
                    pending.removeAll()
                } else {
                    turnOpen = true
                }
            case "assistant":
                sawConversation = true
                let message = entry["message"] as? [String: Any]
                let blocks = content as? [[String: Any]] ?? []
                let toolUses = blocks.filter { $0["type"] as? String == "tool_use" }
                for toolUse in toolUses {
                    if let id = toolUse["id"] as? String {
                        pending.append((id, toolUse["name"] as? String ?? "tool"))
                    }
                }
                if toolUses.isEmpty,
                   let stopReason = message?["stop_reason"] as? String,
                   stopReason == "end_turn" || stopReason == "stop_sequence" {
                    turnOpen = false
                } else {
                    turnOpen = true
                }
            case "system":
                if let subtype = entry["subtype"] as? String,
                   Self.claudeTurnEndSubtypes.contains(subtype) {
                    turnOpen = false
                }
            default:
                continue
            }
        }
        guard sawConversation else { return nil }
        return result(turnOpen: turnOpen, pendingToolName: pending.last?.name,
                      lastTimestamp: lastTimestamp, fileSize: fileSize)
    }

    private func claudeText(_ content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        return (content as? [[String: Any]] ?? []).compactMap { block in
            if let text = block["text"] as? String { return text }
            if let inner = block["content"] as? String { return inner }
            return nil
        }
    }

    private func isClaudeUserInterrupt(_ text: String) -> Bool {
        Self.claudeUserInterruptMarkers.contains { text.contains($0) }
    }

    // MARK: Codex

    private static let codexCallTypes: Set<String> = ["function_call", "custom_tool_call", "local_shell_call"]
    private static let codexOutputTypes: Set<String> = [
        "function_call_output", "custom_tool_call_output", "local_shell_call_output",
    ]

    private func codexInterruption(_ entries: [[String: Any]], fileSize: UInt64) -> AgentInterruption? {
        var turnOpen = false
        var pending: [(id: String, name: String)] = []
        var lastTimestamp: String?
        var sawTurn = false
        for entry in entries {
            if let timestamp = entry["timestamp"] as? String { lastTimestamp = timestamp }
            guard let payload = entry["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            switch entry["type"] as? String {
            case "event_msg":
                switch type {
                case "task_started":
                    sawTurn = true
                    turnOpen = true
                case "task_complete":
                    sawTurn = true
                    pending.removeAll()
                    // A turn that completed on an error (quota, capacity) did
                    // not finish its work.
                    if let error = payload["error"], !(error is NSNull) {
                        turnOpen = true
                    } else {
                        turnOpen = false
                    }
                case "turn_aborted":
                    // The user stopped the turn on purpose.
                    sawTurn = true
                    turnOpen = false
                    pending.removeAll()
                default:
                    continue
                }
            case "response_item":
                if Self.codexCallTypes.contains(type), let callID = payload["call_id"] as? String {
                    sawTurn = true
                    turnOpen = true
                    pending.append((callID, payload["name"] as? String ?? (type == "local_shell_call" ? "shell" : "tool")))
                } else if Self.codexOutputTypes.contains(type), let callID = payload["call_id"] as? String {
                    pending.removeAll { $0.id == callID }
                }
            default:
                continue
            }
        }
        guard sawTurn else { return nil }
        return result(turnOpen: turnOpen, pendingToolName: pending.last?.name,
                      lastTimestamp: lastTimestamp, fileSize: fileSize)
    }

    // MARK: Shared

    private func result(
        turnOpen: Bool,
        pendingToolName: String?,
        lastTimestamp: String?,
        fileSize: UInt64
    ) -> AgentInterruption {
        let state: AgentInterruption.State
        if pendingToolName != nil {
            state = .midToolCall
        } else if turnOpen {
            state = .midTurn
        } else {
            state = .idle
        }
        return AgentInterruption(
            state: state,
            interruptedAt: lastTimestamp.flatMap(Self.parseTimestamp),
            pendingToolName: pendingToolName,
            fingerprint: "\(lastTimestamp ?? "-")#\(fileSize)"
        )
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

/// Finds the transcript a session's agent writes.
public struct AgentTranscriptLocator: Sendable {
    public init() {}

    /// Claude config directories a transcript may live under: the launch's
    /// `CLAUDE_CONFIG_DIR`, `~/.claude`, and Subrouter's proxy directories.
    /// Subrouter shares `projects/` between them, so any one may hold it.
    public func claudeConfigDirectories(environment: [String: String], homeDirectory: String) -> [String] {
        var directories: [String] = []
        if let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            directories.append(configured)
        }
        directories.append((homeDirectory as NSString).appendingPathComponent(".claude"))
        let proxyRoot = (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude-proxy")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: proxyRoot) {
            directories.append(contentsOf: entries.sorted().map { (proxyRoot as NSString).appendingPathComponent($0) })
        }
        return directories
    }

    /// The transcript path for `sessionID` of agent `kind`, or `nil`.
    public func transcriptPath(
        kind: String,
        sessionID: String,
        environment: [String: String],
        homeDirectory: String
    ) -> String? {
        guard CodexSessionModelProviderReader.isWellFormedSessionID(sessionID) else { return nil }
        switch kind.lowercased() {
        case "codex":
            let codexHome = CodexHomeResolver().resolve(
                launchEnvironment: environment,
                ambientEnvironment: ["HOME": homeDirectory]
            )
            return CodexSessionModelProviderReader().rolloutPath(sessionID: sessionID, codexHome: codexHome)
        case "claude":
            let fileManager = FileManager.default
            for directory in claudeConfigDirectories(environment: environment, homeDirectory: homeDirectory) {
                let projects = (directory as NSString).appendingPathComponent("projects")
                guard let slugs = try? fileManager.contentsOfDirectory(atPath: projects) else { continue }
                for slug in slugs.sorted() {
                    let candidate = ((projects as NSString).appendingPathComponent(slug) as NSString)
                        .appendingPathComponent("\(sessionID.lowercased()).jsonl")
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue {
                        return candidate
                    }
                }
            }
            return nil
        default:
            return nil
        }
    }
}
