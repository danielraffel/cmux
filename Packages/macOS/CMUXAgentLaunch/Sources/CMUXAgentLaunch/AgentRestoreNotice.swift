/// Something a restore changed about the recorded launch that the user should
/// see before the agent starts.
public enum AgentRestoreNotice: Equatable, Sendable {
    /// The session was started through a routed launcher that cannot be found
    /// on the restore `PATH`, so the agent resumes directly instead.
    case routedLauncherUnavailable(executable: String)

    /// The Codex session's rollout records the `subrouter` model provider, so a
    /// plain `codex resume` cannot load it, and no Subrouter launcher (`sr`,
    /// `subrouter`, `cx`) can be found on the restore `PATH`.
    case subrouterCodexLauncherUnavailable(sessionID: String)
}
