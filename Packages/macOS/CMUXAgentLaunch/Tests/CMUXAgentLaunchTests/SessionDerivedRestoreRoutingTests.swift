import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Restore routing is decided per session. A Codex session's rollout records the
/// provider it was created with; a record captured without Subrouter's marker
/// pair must still resume a `subrouter` session through `sr codex resume`, and a
/// plain session must never replay stale Subrouter relay options.
@Suite("Restore routing follows the session, not only the captured launch record")
struct SessionDerivedRestoreRoutingTests {
    private let codexSessionID = "01a10852-5eed-7993-bee8-c40693a36dc3"
    private let claudeSessionID = "64823d4f-2711-4ce5-8cf4-2842fa7d3358"
    private let capturedCodex = "/Users/me/.local/bin/codex"
    private let capturedClaude = "/Users/me/.local/bin/claude"
    private let staleRelay = "http://127.0.0.1:58197/0000000000000000000000000000000000000000000000000000000000000000/v1"

    private let ambientEnvironment = [
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
        "HOME": "/Users/me",
        "CMUX_CODEX_WRAPPER_SHIM": "/shim/codex",
        "CMUX_CLAUDE_WRAPPER_SHIM": "/shim/claude",
    ]

    // MARK: - Fixtures

    /// The routing options `sr codex` appends to a routed launch, including the
    /// whole-table spelling, all naming a per-launch relay that is gone after
    /// the launching `sr` exits.
    private var staleRoutingArguments: [String] {
        [
            "-c", #"model_provider="subrouter""#,
            "-c", #"model_providers.subrouter.name="Subrouter""#,
            "-c", "model_providers.subrouter.base_url=\"\(staleRelay)\"",
            "-c", #"model_providers.subrouter.wire_api="responses""#,
            "-c", "model_providers.subrouter={name=\"Subrouter\",base_url=\"\(staleRelay)\"}",
        ]
    }

    private func codexRequest(
        arguments: [String],
        environment: [String: String] = [:]
    ) -> AgentRestoreRequest {
        AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "codex",
            checkpointID: codexSessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/project",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: "codex",
                executablePath: capturedCodex,
                arguments: arguments,
                workingDirectory: "/tmp/project",
                environment: environment,
                capturedAt: 1,
                source: "test"
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
    }

    private func planner(
        executables: Set<String> = ["/opt/homebrew/bin/sr", "/shim/codex", "/shim/claude"],
        provider: String?,
        reads: ReadCounter = ReadCounter()
    ) -> AgentRestorePlanner {
        AgentRestorePlanner(
            isExecutableFile: { executables.contains($0) },
            codexSessionModelProvider: { _, _ in
                reads.increment()
                return provider
            }
        )
    }

    private func expectNoSubrouterRouting(_ arguments: [String], _ label: String) {
        #expect(arguments.allSatisfy { !$0.contains("subrouter") }, "\(label): \(arguments)")
        #expect(arguments.allSatisfy { !$0.contains("127.0.0.1:58197") }, "\(label): \(arguments)")
    }

    // MARK: - Codex: the rollout decides when the record cannot

    @Test("A subrouter session whose record lost its marker resumes through sr codex resume")
    func markerlessSubrouterSessionResumesThroughSubrouter() throws {
        let invocation = try #require(planner(provider: "subrouter").invocation(
            for: codexRequest(arguments: [capturedCodex, "-m", "gpt-6-astra", "--yolo"]),
            ambientEnvironment: ambientEnvironment
        ))

        #expect(Array(invocation.arguments.prefix(4)) == ["sr", "codex", "resume", codexSessionID],
                "\(invocation.arguments)")
        #expect(invocation.arguments.contains("--yolo"))
        #expect(!invocation.arguments.contains("model_provider=subrouter"),
                "sr owns the provider block: \(invocation.arguments)")
        #expect(invocation.environment["SUBROUTER_CODEX_BIN"] == "/shim/codex")
        #expect(invocation.environment["SUBROUTER_CODEX_RESUME_COMMAND"] == nil)
        #expect(invocation.notices.isEmpty)
    }

    @Test("A stale record replaying a dead relay is repaired to sr codex resume without it")
    func staleRelayRecordIsRepaired() throws {
        let invocation = try #require(planner(provider: "subrouter").invocation(
            for: codexRequest(arguments: [capturedCodex] + staleRoutingArguments + ["--yolo"]),
            ambientEnvironment: ambientEnvironment
        ))

        #expect(Array(invocation.arguments.prefix(4)) == ["sr", "codex", "resume", codexSessionID],
                "\(invocation.arguments)")
        #expect(invocation.arguments.allSatisfy { !$0.contains(staleRelay) }, "\(invocation.arguments)")
        #expect(invocation.arguments.allSatisfy { !$0.hasPrefix("model_providers.subrouter") },
                "\(invocation.arguments)")
    }

    @Test("A plain session resumes with plain codex and drops stale Subrouter options")
    func plainSessionDropsStaleRouting() throws {
        let invocation = try #require(planner(provider: "openai").invocation(
            for: codexRequest(
                arguments: [capturedCodex] + staleRoutingArguments + ["--yolo"],
                environment: ["SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume"]
            ),
            ambientEnvironment: ambientEnvironment
        ))

        #expect(invocation.arguments.first != "sr", "\(invocation.arguments)")
        #expect(invocation.arguments.contains("resume"))
        #expect(invocation.arguments.contains(codexSessionID))
        #expect(invocation.arguments.contains("--yolo"))
        expectNoSubrouterRouting(invocation.arguments, "plain")
        #expect(invocation.environment["SUBROUTER_CODEX_RESUME_COMMAND"] == nil)
    }

    @Test("A plain session with a plain record is restored exactly as before")
    func plainSessionIsUnchanged() throws {
        let request = codexRequest(arguments: [capturedCodex, "-m", "gpt-6-astra"])
        let repaired = try #require(planner(provider: "openai").invocation(
            for: request, ambientEnvironment: ambientEnvironment
        ))
        let unread = try #require(planner(provider: nil).invocation(
            for: request, ambientEnvironment: ambientEnvironment
        ))

        #expect(repaired == unread)
        #expect(repaired.arguments.first != "sr")
        expectNoSubrouterRouting(repaired.arguments, "plain record")
    }

    @Test("An unreadable rollout leaves the record to the existing restore")
    func unreadableRolloutKeepsRecord() throws {
        let request = codexRequest(arguments: [capturedCodex] + staleRoutingArguments)
        let invocation = try #require(planner(provider: nil).invocation(
            for: request, ambientEnvironment: ambientEnvironment
        ))
        #expect(invocation.arguments.first != "sr")
        #expect(invocation.arguments.contains(#"model_provider="subrouter""#))
    }

    @Test("A subrouter session with no Subrouter launcher on PATH says how to fix it")
    func missingLauncherProducesActionableNotice() throws {
        let invocation = try #require(planner(executables: ["/shim/codex"], provider: "subrouter").invocation(
            for: codexRequest(arguments: [capturedCodex, "--yolo"]),
            ambientEnvironment: ambientEnvironment
        ))

        #expect(invocation.notices == [.subrouterCodexLauncherUnavailable(sessionID: codexSessionID)])
        #expect(invocation.arguments.first != "sr")
    }

    @Test("A proven route whose launcher resolves never reads the rollout")
    func provenRouteSkipsRolloutRead() throws {
        let reads = ReadCounter()
        let invocation = try #require(planner(provider: "openai", reads: reads).invocation(
            for: codexRequest(
                arguments: [capturedCodex, "-c", "model_provider=subrouter"],
                environment: [
                    "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                    "CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                ]
            ),
            ambientEnvironment: ambientEnvironment
        ))
        #expect(reads.count == 0)
        #expect(Array(invocation.arguments.prefix(4)) == ["sr", "codex", "resume", codexSessionID])
    }

    @Test("A proven sr route falls back to another Subrouter launcher on PATH")
    func provenRouteSwitchesToResolvableLauncher() throws {
        let invocation = try #require(planner(
            executables: ["/opt/homebrew/bin/subrouter", "/shim/codex"],
            provider: "subrouter"
        ).invocation(
            for: codexRequest(
                arguments: [capturedCodex, "-c", "model_provider=subrouter"],
                environment: [
                    "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                    "CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                ]
            ),
            ambientEnvironment: ambientEnvironment
        ))
        #expect(Array(invocation.arguments.prefix(4)) == ["subrouter", "codex", "resume", codexSessionID],
                "\(invocation.arguments)")
    }

    @Test("A proven sr route whose launcher is gone resumes a plain session directly")
    func provenRouteWithMissingLauncherAndPlainRollout() throws {
        let invocation = try #require(planner(executables: ["/shim/codex"], provider: "openai").invocation(
            for: codexRequest(
                arguments: [capturedCodex, "--yolo"] + staleRoutingArguments,
                environment: [
                    "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                    "CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                ]
            ),
            ambientEnvironment: ambientEnvironment
        ))
        #expect(invocation.arguments.first != "sr", "\(invocation.arguments)")
        #expect(invocation.arguments.contains(codexSessionID))
        expectNoSubrouterRouting(invocation.arguments, "proven route, launcher gone, plain rollout")
        #expect(invocation.environment["SUBROUTER_CODEX_RESUME_COMMAND"] == nil)
        #expect(invocation.notices.isEmpty)
    }

    @Test("A proven route never replays the whole-table relay spelling")
    func provenRouteStripsWholeTableSpelling() throws {
        let invocation = try #require(planner(provider: "subrouter").invocation(
            for: codexRequest(
                arguments: [capturedCodex, "--yolo"] + staleRoutingArguments,
                environment: [
                    "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                    "CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                ]
            ),
            ambientEnvironment: ambientEnvironment
        ))
        #expect(Array(invocation.arguments.prefix(4)) == ["sr", "codex", "resume", codexSessionID])
        #expect(invocation.arguments.allSatisfy { !$0.contains(staleRelay) }, "\(invocation.arguments)")
    }

    @Test("The whole-table relay spelling is private on public surfaces")
    func wholeTableSpellingIsPrivate() {
        let redacted = SubrouterCodexResumeRouting().removingPrivateRoutingArguments(
            from: [capturedCodex, "--yolo"] + staleRoutingArguments
        )
        #expect(redacted == [capturedCodex, "--yolo"])
    }

    // MARK: - Codex: the rollout reader, against fixture rollouts

    @Test(
        "The rollout reader returns the provider recorded in session_meta",
        arguments: [("subrouter", "sessions/2026/10/04"), ("openai", "sessions/2026/10/04"), ("subrouter", "archived_sessions")]
    )
    func readerReadsSessionMeta(provider: String, directory: String) throws {
        let home = try FixtureCodexHome()
        defer { home.remove() }
        try home.writeRollout(sessionID: codexSessionID, provider: provider, directory: directory)

        #expect(CodexSessionModelProviderReader().modelProvider(
            sessionID: codexSessionID, codexHome: home.path
        ) == provider)
    }

    @Test("The rollout reader rejects a mismatched id, a missing rollout and a malformed id")
    func readerRejectsUnprovenRollouts() throws {
        let home = try FixtureCodexHome()
        defer { home.remove() }
        try home.writeRollout(
            sessionID: codexSessionID,
            provider: "subrouter",
            directory: "sessions/2026/10/04",
            metaID: "01a10852-0000-7000-8000-000000000000"
        )
        let reader = CodexSessionModelProviderReader()

        #expect(reader.modelProvider(sessionID: codexSessionID, codexHome: home.path) == nil)
        #expect(reader.modelProvider(sessionID: "01a10852-1111-7000-8000-000000000000", codexHome: home.path) == nil)
        #expect(reader.modelProvider(sessionID: "../../etc/passwd", codexHome: home.path) == nil)
    }

    @Test("The default planner finds the rollout under the record's CODEX_HOME")
    func defaultPlannerReadsRecordedCodexHome() throws {
        let home = try FixtureCodexHome()
        defer { home.remove() }
        try home.writeRollout(sessionID: codexSessionID, provider: "subrouter", directory: "sessions/2026/10/04")

        let invocation = try #require(AgentRestorePlanner(
            isExecutableFile: { ["/opt/homebrew/bin/sr", "/shim/codex"].contains($0) }
        ).invocation(
            for: codexRequest(arguments: [capturedCodex, "--yolo"], environment: ["CODEX_HOME": home.path]),
            ambientEnvironment: ambientEnvironment
        ))
        #expect(Array(invocation.arguments.prefix(4)) == ["sr", "codex", "resume", codexSessionID],
                "\(invocation.arguments)")
    }

    // MARK: - Claude: the captured launch evidence decides

    private func claudeRequest(arguments: [String], environment: [String: String]) -> AgentRestoreRequest {
        AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "claude",
            checkpointID: claudeSessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/project",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: nil,
                executablePath: capturedClaude,
                arguments: arguments,
                workingDirectory: "/tmp/project",
                environment: environment,
                capturedAt: 1,
                source: "test"
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
    }

    @Test("A Claude session launched through sr resumes through sr claude proxy --resume")
    func routedClaudeSession() throws {
        let invocation = try #require(planner(provider: nil).invocation(
            for: claudeRequest(arguments: [capturedClaude], environment: [
                "SUBROUTER_CLAUDE_RESUME_COMMAND": "sr claude proxy --resume",
                "CMUX_AGENT_LAUNCH_SUBROUTER_CLAUDE_RESUME_COMMAND": "sr claude proxy --resume",
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:31415/v1",
                "CLAUDE_CONFIG_DIR": "/Users/me/.subrouter/codex/claude-proxy/25bf8e1a2393f1108d37029b",
            ]),
            ambientEnvironment: ambientEnvironment
        ))
        #expect(Array(invocation.arguments.prefix(5)) == ["sr", "claude", "proxy", "--resume", claudeSessionID])
    }

    @Test("A Claude session launched without sr resumes with plain claude --resume")
    func plainClaudeSession() throws {
        let invocation = try #require(planner(provider: "subrouter").invocation(
            for: claudeRequest(arguments: [capturedClaude, "--permission-mode", "auto"], environment: [:]),
            ambientEnvironment: ambientEnvironment
        ))
        #expect(invocation.arguments.first == "/shim/claude", "\(invocation.arguments)")
        #expect(invocation.arguments.contains("--resume"))
        #expect(!invocation.arguments.contains("sr"))
    }

    @Test("A stale pre-marker Claude record with a deleted sr settings file still resumes through sr")
    func staleClaudeRecordResumesThroughSubrouter() throws {
        let invocation = try #require(planner(provider: nil).invocation(
            for: claudeRequest(
                arguments: [capturedClaude, "--settings", "/var/folders/xx/T/subrouter-claude-settings-804303911/settings.json"],
                environment: [
                    "ANTHROPIC_BASE_URL": "http://127.0.0.1:31415/v1",
                    "CLAUDE_CONFIG_DIR": "/Users/me/.subrouter/codex/claude-proxy/3fa7ce27b6c3bad79bd47d1a",
                ]
            ),
            ambientEnvironment: ambientEnvironment
        ))
        #expect(Array(invocation.arguments.prefix(5)) == ["sr", "claude", "proxy", "--resume", claudeSessionID],
                "\(invocation.arguments)")
        #expect(invocation.arguments.allSatisfy { !$0.contains("subrouter-claude-settings-") })
    }
}

/// Counts reads of the injected rollout provider across the planner's closure.
final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

/// A throwaway `CODEX_HOME` holding fixture rollouts.
struct FixtureCodexHome {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-home-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func writeRollout(sessionID: String, provider: String, directory: String, metaID: String? = nil) throws {
        let directoryPath = (path as NSString).appendingPathComponent(directory)
        try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "timestamp": "2026-10-04T19:09:38.437Z",
            "type": "session_meta",
            "payload": [
                "id": metaID ?? sessionID,
                "cwd": "/tmp/project",
                "originator": "codex-tui",
                "model_provider": provider,
                "base_instructions": ["text": String(repeating: "x", count: 200_000)],
            ],
        ]
        let turn: [String: Any] = ["type": "response_item", "payload": ["type": "message"]]
        let lines = try [meta, turn].map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        let file = (directoryPath as NSString)
            .appendingPathComponent("rollout-2026-10-04T12-09-38-\(sessionID).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
