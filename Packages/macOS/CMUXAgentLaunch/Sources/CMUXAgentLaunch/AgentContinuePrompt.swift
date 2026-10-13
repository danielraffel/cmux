import Foundation

/// The one prompt cmux and Subrouter send to make an interrupted session go on.
///
/// A resumed agent has its transcript, so it knows every step up to the last
/// one that completed. It cannot know the outcome of the step that was in
/// flight when it stopped: a half-run command, a push, a pull request edit, a
/// background job. The prompt therefore never just says "continue". It names
/// when the session stopped, says whether a tool call was left open, and asks
/// the agent to check the real state of everything in progress, report what
/// is done and what is not, and continue only the unfinished parts.
///
/// Every sender (restore auto-continue, cmux's retryable-failure auto-resume,
/// Subrouter's quota and provider recovery) builds its text here; Subrouter
/// obtains it through `cmux agent-continue-prompt`.
public struct AgentContinuePrompt: Sendable {
    /// Why the session is being asked to continue.
    public enum Reason: String, Sendable, CaseIterable {
        /// The agent process stopped (crash, kill, cmux quit) and was relaunched.
        case restored
        /// The session's account ran out of quota and has quota again.
        case quotaRecovered = "quota"
        /// A temporary provider failure (capacity, overload, dropped connection) passed.
        case providerRecovered = "provider"
    }

    public init() {}

    /// Returns the prompt for `interruption`, or `nil` for an idle session,
    /// which must never be continued.
    public func text(
        for interruption: AgentInterruption,
        reason: Reason,
        timeZone: TimeZone = .current
    ) -> String? {
        guard interruption.state != .idle else { return nil }
        let when = interruption.interruptedAt.map { Self.format($0, timeZone: timeZone) } ?? "an unknown time"
        let cause: String
        switch reason {
        case .restored:
            cause = "Your session stopped at \(when) and has been relaunched."
        case .quotaRecovered:
            cause = "Your session stopped at \(when) when its account ran out of quota; quota is available again."
        case .providerRecovered:
            cause = "Your session stopped at \(when) on a temporary provider failure, which has passed."
        }
        let inFlight: String
        switch interruption.state {
        case .midToolCall:
            let tool = interruption.pendingToolName.map { " (\($0))" } ?? ""
            inFlight = "Your last tool call\(tool) has no recorded result, so it may or may not have run or finished."
        case .midTurn, .idle:
            inFlight = "Your last action may not have completed."
        }
        return [
            cause,
            inFlight,
            "Before doing anything else, check the real state of everything that was in progress: git status and git log, the state of any branch or pull request through the API, running processes, and any files you were writing.",
            "Then report what is done and what is not, and continue only the unfinished parts. Never redo a step whose effect already exists.",
        ].joined(separator: " ")
    }

    static func format(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let utc = ISO8601DateFormatter()
        utc.formatOptions = [.withInternetDateTime]
        return "\(formatter.string(from: date)) (\(utc.string(from: date)))"
    }
}
