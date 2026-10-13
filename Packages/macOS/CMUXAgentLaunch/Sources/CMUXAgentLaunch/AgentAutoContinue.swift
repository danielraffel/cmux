import Foundation

/// Records which interruptions have already been sent a continue prompt, so
/// each interruption gets at most one, across cmux restores, cmux's own
/// auto-resume and Subrouter's resumer.
///
/// A claim is one file created with `O_CREAT | O_EXCL` under ``directory``,
/// named from the agent, session and interruption fingerprint. The filesystem
/// makes the claim atomic between processes; the first claimer wins.
public struct AgentAutoContinueLedger: Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    /// The ledger shared by every sender on this Mac.
    public static func standard(homeDirectory: String = NSHomeDirectory()) -> AgentAutoContinueLedger {
        AgentAutoContinueLedger(
            directory: (homeDirectory as NSString)
                .appendingPathComponent("Library/Application Support/cmux/agent-auto-continue")
        )
    }

    /// Claims `interruption` of `sessionID`. Returns `true` exactly once per
    /// interruption; every later call, from any process, returns `false`.
    public func claim(kind: String, sessionID: String, interruption: AgentInterruption) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let path = (directory as NSString).appendingPathComponent(entryName(
            kind: kind, sessionID: sessionID, fingerprint: interruption.fingerprint
        ))
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        let record = Self.record(kind: kind, sessionID: sessionID, interruption: interruption)
        record.withUnsafeBytes { bytes in
            _ = write(descriptor, bytes.baseAddress, bytes.count)
        }
        close(descriptor)
        return true
    }

    /// The claim's contents: when the session was interrupted, whether a tool
    /// call was left open, and when the continue prompt was sent.
    static func record(kind: String, sessionID: String, interruption: AgentInterruption) -> Data {
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = [
            "kind": kind,
            "session_id": sessionID,
            "state": interruption.state.rawValue,
            "last_entry_was_open_tool_call": interruption.state == .midToolCall,
            "fingerprint": interruption.fingerprint,
            "continue_sent_at": formatter.string(from: Date()),
        ]
        object["interrupted_at"] = interruption.interruptedAt.map { formatter.string(from: $0) }
        object["pending_tool"] = interruption.pendingToolName
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// An opaque token for `interruption`, handed to a sender that delivers
    /// the prompt itself and claims only after a successful submit. Claiming
    /// with the token records the interruption the prompt was built for, not
    /// whatever the transcript says after the prompt landed.
    public static func claimToken(for interruption: AgentInterruption) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return ((try? encoder.encode(interruption)) ?? Data()).base64EncodedString()
    }

    /// Decodes a token from ``claimToken(for:)``, or `nil` when malformed.
    public static func interruption(fromClaimToken token: String) -> AgentInterruption? {
        guard let data = Data(base64Encoded: token.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentInterruption.self, from: data)
    }

    /// Reads a claim back, for diagnostics and tests.
    public func claimRecord(kind: String, sessionID: String, interruption: AgentInterruption) -> [String: Any]? {
        let path = (directory as NSString).appendingPathComponent(entryName(
            kind: kind, sessionID: sessionID, fingerprint: interruption.fingerprint
        ))
        return FileManager.default.contents(atPath: path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Whether `interruption` was already claimed.
    public func isClaimed(kind: String, sessionID: String, interruption: AgentInterruption) -> Bool {
        FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(entryName(
            kind: kind, sessionID: sessionID, fingerprint: interruption.fingerprint
        )))
    }

    private func entryName(kind: String, sessionID: String, fingerprint: String) -> String {
        let raw = "\(kind.lowercased())|\(sessionID.lowercased())|\(fingerprint)"
        // FNV-1a keeps the name short and free of path characters.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        let safeSession = sessionID.filter { $0.isHexDigit || $0 == "-" }
        return "\(kind.lowercased())-\(safeSession)-\(String(hash, radix: 16)).claim"
    }
}

/// Decides whether a session gets a continue prompt.
public struct AgentAutoContinuePolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Send this prompt; the interruption is now claimed.
        case send(prompt: String, interruption: AgentInterruption)
        /// Auto-continue is off for this session.
        case disabled
        /// The transcript could not be read or classified.
        case unknown
        /// The session finished its last turn, or the user stopped it.
        case idle
        /// This interruption already received its continue prompt.
        case alreadySent
    }

    public init() {}

    /// - Parameters:
    ///   - enabledSetting: The global "continue where it left off" setting (default off).
    ///   - sessionOverride: A per-session choice that wins over the setting when present.
    ///   - interruption: The transcript reading, or `nil` when unreadable.
    ///   - claim: Claims the interruption; called only when everything else allows a send.
    public func decide(
        kind: String,
        sessionID: String,
        enabledSetting: Bool,
        sessionOverride: Bool?,
        interruption: AgentInterruption?,
        reason: AgentContinuePrompt.Reason,
        claim: (AgentInterruption) -> Bool
    ) -> Decision {
        guard sessionOverride ?? enabledSetting else { return .disabled }
        guard let interruption else { return .unknown }
        guard let prompt = AgentContinuePrompt().text(for: interruption, reason: reason) else { return .idle }
        guard claim(interruption) else { return .alreadySent }
        return .send(prompt: prompt, interruption: interruption)
    }
}

/// Reads a session's transcript and applies ``AgentAutoContinuePolicy`` with
/// the shared ledger. The one entry point for every continue sender.
public struct AgentAutoContinueService: Sendable {
    /// Restore-record environment key holding a per-session override: `1` on, `0` off.
    public static let sessionOverrideEnvironmentKey = "CMUX_AGENT_AUTO_CONTINUE"
    /// cmux defaults key for the global setting (default off).
    public static let settingDefaultsKey = "agentAutoContinueAfterRestore"

    public let ledger: AgentAutoContinueLedger
    public let homeDirectory: String

    public init(ledger: AgentAutoContinueLedger, homeDirectory: String) {
        self.ledger = ledger
        self.homeDirectory = homeDirectory
    }

    /// The per-session override recorded in a launch environment, if any.
    public static func sessionOverride(in environment: [String: String]?) -> Bool? {
        switch environment?[sessionOverrideEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "on", "yes": return true
        case "0", "false", "off", "no": return false
        default: return nil
        }
    }

    /// How a decision uses the ledger.
    public enum LedgerMode: Sendable, Equatable {
        /// Claim the interruption; only the first claimer sends.
        case claim
        /// Report what would be sent without consuming the interruption.
        case dryRun
        /// The retry of a launch that already claimed this interruption and
        /// never delivered its prompt: send only if the claim exists.
        case carry
    }

    /// Reads the session's transcript and decides.
    public func decide(
        kind: String,
        sessionID: String,
        environment: [String: String],
        enabledSetting: Bool,
        sessionOverride: Bool?,
        reason: AgentContinuePrompt.Reason,
        ledgerMode: LedgerMode = .claim
    ) -> AgentAutoContinuePolicy.Decision {
        let interruption = AgentTranscriptLocator()
            .transcriptPath(kind: kind, sessionID: sessionID, environment: environment, homeDirectory: homeDirectory)
            .flatMap { AgentInterruptionReader().interruption(kind: kind, transcriptPath: $0) }
        return AgentAutoContinuePolicy().decide(
            kind: kind,
            sessionID: sessionID,
            enabledSetting: enabledSetting,
            sessionOverride: sessionOverride,
            interruption: interruption,
            reason: reason,
            claim: { interruption in
                switch ledgerMode {
                case .claim:
                    return ledger.claim(kind: kind, sessionID: sessionID, interruption: interruption)
                case .dryRun:
                    return !ledger.isClaimed(kind: kind, sessionID: sessionID, interruption: interruption)
                case .carry:
                    return ledger.isClaimed(kind: kind, sessionID: sessionID, interruption: interruption)
                }
            }
        )
    }
}
