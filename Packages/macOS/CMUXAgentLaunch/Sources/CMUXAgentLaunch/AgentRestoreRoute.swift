import Foundation

/// Which launcher a restore resumes an agent session through.
public enum AgentRestoreRoute: String, Sendable, Equatable, CaseIterable {
    /// Decided per session: launch evidence first, then the session's own files.
    case automatic
    /// Through Subrouter: `sr codex resume <id>` or `sr claude proxy --resume <id>`.
    case subrouter
    /// Through the agent directly: `codex resume <id>` or `claude --resume <id>`.
    case plain

    /// The route a failed launch retries with.
    public var alternate: AgentRestoreRoute {
        self == .subrouter ? .plain : .subrouter
    }

    /// The route an invocation actually took, from its argv[0].
    public static func taken(by invocation: AgentRestoreInvocation) -> AgentRestoreRoute {
        guard let first = invocation.arguments.first else { return .plain }
        let name = (first as NSString).lastPathComponent
        return SubrouterCodexResumeRouting.supportedLaunchers.contains(name) ? .subrouter : .plain
    }
}

/// Rewrites a restore request so it resumes through a forced route. Used for
/// the one retry after a launch through the automatically chosen route did not
/// reach its prompt.
struct AgentRestoreRouteOverride {
    private let codexRouter = SubrouterCodexResumeRouting()
    private let claudeRouter = SubrouterClaudeResumeRouting()

    func applying(
        _ route: AgentRestoreRoute,
        to request: AgentRestoreRequest,
        kind: String,
        isLauncherResolvable: (String) -> Bool
    ) -> AgentRestoreRequest {
        guard route != .automatic,
              request.mode == .resumeAgent,
              var launch = request.launchCommand,
              !launch.arguments.isEmpty else {
            return request
        }
        var requestEnvironment = request.environment
        switch (kind, route) {
        case ("codex", .subrouter):
            guard let launcher = SubrouterCodexResumeRouting.supportedLaunchers.first(where: isLauncherResolvable),
                  let markers = codexRouter.markerEnvironment(launcher: launcher) else {
                return request
            }
            launch.environment = (launch.environment ?? [:]).merging(markers) { _, marker in marker }
            launch.arguments = codexRouter.argumentsProvingSubrouterProvider(launch.arguments)
        case ("codex", .plain):
            launch.arguments = codexRouter.removingPrivateRoutingArguments(from: launch.arguments)
            for key in [SubrouterCodexResumeRouting.environmentKey, SubrouterCodexResumeRouting.launchBoundEnvironmentKey] {
                launch.environment?.removeValue(forKey: key)
                requestEnvironment.removeValue(forKey: key)
            }
        case ("claude", .subrouter):
            guard let launcher = ["sr", "subrouter"].first(where: isLauncherResolvable),
                  let marker = claudeRouter.canonicalMarker("\(launcher) claude proxy --resume") else {
                return request
            }
            launch.environment = (launch.environment ?? [:]).merging([
                SubrouterClaudeResumeRouting.environmentKey: marker,
                SubrouterClaudeResumeRouting.launchBoundEnvironmentKey: marker,
            ]) { _, marker in marker }
        case ("claude", .plain):
            let routingKeys = [
                SubrouterClaudeResumeRouting.environmentKey,
                SubrouterClaudeResumeRouting.launchBoundEnvironmentKey,
                SubrouterClaudeResumeRouting.accountEnvironmentKey,
                "ANTHROPIC_BASE_URL",
            ]
            for key in routingKeys {
                launch.environment?.removeValue(forKey: key)
                requestEnvironment.removeValue(forKey: key)
            }
            // A Subrouter-owned config directory routes through the proxy by
            // itself; a plain resume uses the default Claude config.
            if Self.isSubrouterOwned(launch.environment?["CLAUDE_CONFIG_DIR"]) {
                launch.environment?.removeValue(forKey: "CLAUDE_CONFIG_DIR")
            }
            if Self.isSubrouterOwned(requestEnvironment["CLAUDE_CONFIG_DIR"]) {
                requestEnvironment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
            }
            launch.launcherPrefix = nil
            launch.arguments = claudeRouter.removingPrivateSettingsArguments(from: launch.arguments)
        default:
            return request
        }
        return request.replacingLaunchCommand(launch, environment: requestEnvironment)
    }

    private static func isSubrouterOwned(_ directory: String?) -> Bool {
        guard let directory else { return false }
        return URL(fileURLWithPath: directory).standardized.pathComponents.contains(".subrouter")
    }
}

/// Decides, after a restored agent's process is gone or has survived its grace
/// period, whether the restore reached the agent's prompt and what to do next.
public struct AgentRestoreLaunchVerification: Sendable {
    /// How long a resumed agent must stay alive to count as having reached its
    /// prompt when it emits no session-start evidence. Launch failures such as
    /// an unknown model provider, a missing launcher or a refused login exit
    /// well within it.
    public static let gracePeriod: TimeInterval = 20

    public enum Next: Equatable, Sendable {
        /// The agent reached its prompt; nothing to do.
        case verified
        /// Still inside the grace period; check again when the process exits
        /// or the period ends.
        case pending
        /// Retry once through this route.
        case retry(AgentRestoreRoute)
        /// Both routes failed; show this on the surface.
        case giveUp(message: String)
    }

    public init() {}

    /// - Parameters:
    ///   - processAlive: Whether the agent is still running at the time of the check.
    ///   - elapsed: Seconds since the agent was launched.
    ///   - sessionEvidence: The agent recorded activity for the session after launch
    ///     (a session-start hook for this id, or a transcript that changed).
    ///   - attempt: 1 for the first launch, 2 for the retry.
    ///   - route: The route this attempt used.
    public func next(
        kind: String,
        sessionID: String,
        processAlive: Bool,
        elapsed: TimeInterval,
        sessionEvidence: Bool,
        attempt: Int,
        route: AgentRestoreRoute
    ) -> Next {
        if sessionEvidence || (processAlive && elapsed >= Self.gracePeriod) {
            return .verified
        }
        if processAlive {
            return .pending
        }
        if attempt < 2 {
            return .retry(route.alternate)
        }
        return .giveUp(message: Self.failureMessage(kind: kind, sessionID: sessionID))
    }

    static func failureMessage(kind: String, sessionID: String) -> String {
        let agent = kind == "claude" ? "Claude" : "Codex"
        let routed = kind == "claude" ? "sr claude proxy --resume \(sessionID)" : "sr codex resume \(sessionID)"
        let plain = kind == "claude" ? "claude --resume \(sessionID)" : "codex resume \(sessionID)"
        return "cmux could not resume this \(agent) session (\(sessionID)): it exited before reaching its prompt, both through Subrouter and directly. Check that Subrouter is running (\"sr status\") if the session was started with sr, then run \"\(routed)\" or \"\(plain)\" here."
    }
}
