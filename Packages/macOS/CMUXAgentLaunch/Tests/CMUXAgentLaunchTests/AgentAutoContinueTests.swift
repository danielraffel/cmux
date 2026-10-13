import Foundation
import Testing
@testable import CMUXAgentLaunch

// MARK: - Transcript fixtures

private enum Fixture {
    static let claudeSession = "64823d4f-2711-4ce5-8cf4-2842fa7d3358"
    static let codexSession = "01a10852-5eed-7993-bee8-c40693a36dc3"

    static func claudeUser(_ text: String, at time: String, meta: Bool = false) -> [String: Any] {
        ["type": "user", "timestamp": time, "isMeta": meta, "message": ["role": "user", "content": text]]
    }

    static func claudeToolUse(id: String, name: String, at time: String, sidechain: Bool = false) -> [String: Any] {
        [
            "type": "assistant", "timestamp": time, "isSidechain": sidechain,
            "message": [
                "role": "assistant", "stop_reason": "tool_use",
                "content": [["type": "tool_use", "id": id, "name": name, "input": [:] as [String: Any]]],
            ],
        ]
    }

    static func claudeToolResult(id: String, at time: String) -> [String: Any] {
        [
            "type": "user", "timestamp": time,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]],
        ]
    }

    static func claudeAnswer(at time: String) -> [String: Any] {
        [
            "type": "assistant", "timestamp": time,
            "message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "Done."]]],
        ]
    }

    static func claudeSystem(_ subtype: String, at time: String) -> [String: Any] {
        ["type": "system", "subtype": subtype, "timestamp": time]
    }

    static func codexEvent(_ type: String, at time: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "event_msg", "timestamp": time, "payload": ["type": type].merging(extra) { _, new in new }]
    }

    static func codexCall(_ type: String = "custom_tool_call", id: String, name: String, at time: String) -> [String: Any] {
        ["type": "response_item", "timestamp": time, "payload": ["type": type, "call_id": id, "name": name]]
    }

    static func codexOutput(_ type: String = "custom_tool_call_output", id: String, at time: String) -> [String: Any] {
        ["type": "response_item", "timestamp": time, "payload": ["type": type, "call_id": id]]
    }

    static func write(_ entries: [[String: Any]], to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let lines = try entries.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func temporaryDirectory() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-auto-continue-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}

@Suite("A session's transcript says whether it was interrupted mid-task")
struct AgentInterruptionReaderTests {
    private let reader = AgentInterruptionReader()

    private func state(_ kind: String, _ entries: [[String: Any]]) -> AgentInterruption? {
        reader.interruption(kind: kind, entries: entries, fileSize: 100)
    }

    @Test("Claude: a finished turn is idle")
    func claudeFinishedTurnIsIdle() {
        let result = state("claude", [
            Fixture.claudeUser("fix the build", at: "2026-10-13T10:00:00.000Z"),
            Fixture.claudeToolUse(id: "t1", name: "Bash", at: "2026-10-13T10:00:01.000Z"),
            Fixture.claudeToolResult(id: "t1", at: "2026-10-13T10:00:05.000Z"),
            Fixture.claudeAnswer(at: "2026-10-13T10:00:09.000Z"),
            Fixture.claudeSystem("turn_duration", at: "2026-10-13T10:00:09.100Z"),
        ])
        #expect(result?.state == .idle)
    }

    @Test("Claude: a tool call with no result is mid-tool-call, named, and timed")
    func claudeOpenToolCall() throws {
        let result = try #require(state("claude", [
            Fixture.claudeUser("push the branch", at: "2026-10-13T10:00:00.000Z"),
            Fixture.claudeToolUse(id: "t1", name: "Bash", at: "2026-10-13T10:00:01.500Z"),
        ]))
        #expect(result.state == .midToolCall)
        #expect(result.pendingToolName == "Bash")
        #expect(result.interruptedAt == AgentInterruptionReader.parseTimestamp("2026-10-13T10:00:01.500Z"))
    }

    @Test("Claude: a returned tool result with no answer yet is mid-turn")
    func claudeAwaitingAnswer() {
        let result = state("claude", [
            Fixture.claudeUser("push the branch", at: "2026-10-13T10:00:00.000Z"),
            Fixture.claudeToolUse(id: "t1", name: "Bash", at: "2026-10-13T10:00:01.000Z"),
            Fixture.claudeToolResult(id: "t1", at: "2026-10-13T10:00:03.000Z"),
        ])
        #expect(result?.state == .midTurn)
    }

    @Test("Claude: a turn that stopped on API errors is mid-turn")
    func claudeApiError() {
        let result = state("claude", [
            Fixture.claudeUser("continue", at: "2026-10-13T10:00:00.000Z"),
            Fixture.claudeSystem("api_error", at: "2026-10-13T10:00:02.000Z"),
            Fixture.claudeSystem("api_error", at: "2026-10-13T10:00:04.000Z"),
        ])
        #expect(result?.state == .midTurn)
    }

    @Test("Claude: a turn the user interrupted is idle")
    func claudeUserInterrupt() {
        let result = state("claude", [
            Fixture.claudeUser("refactor it", at: "2026-10-13T10:00:00.000Z"),
            Fixture.claudeToolUse(id: "t1", name: "Edit", at: "2026-10-13T10:00:01.000Z"),
            Fixture.claudeUser("[Request interrupted by user for tool use]", at: "2026-10-13T10:00:02.000Z"),
        ])
        #expect(result?.state == .idle)
    }

    @Test("Claude: a subagent's open tool call does not make the main session busy")
    func claudeSidechainIgnored() {
        let result = state("claude", [
            Fixture.claudeUser("hi", at: "2026-10-13T10:00:00.000Z"),
            Fixture.claudeAnswer(at: "2026-10-13T10:00:01.000Z"),
            Fixture.claudeToolUse(id: "s1", name: "Bash", at: "2026-10-13T10:00:02.000Z", sidechain: true),
        ])
        #expect(result?.state == .idle)
    }

    @Test("Codex: a completed turn is idle")
    func codexCompletedTurn() {
        let result = state("codex", [
            Fixture.codexEvent("task_started", at: "2026-10-13T10:00:00.000Z"),
            Fixture.codexCall(id: "c1", name: "exec", at: "2026-10-13T10:00:01.000Z"),
            Fixture.codexOutput(id: "c1", at: "2026-10-13T10:00:02.000Z"),
            Fixture.codexEvent("task_complete", at: "2026-10-13T10:00:03.000Z", extra: ["error": NSNull()]),
        ])
        #expect(result?.state == .idle)
    }

    @Test("Codex: a call with no output is mid-tool-call")
    func codexOpenCall() throws {
        let result = try #require(state("codex", [
            Fixture.codexEvent("task_started", at: "2026-10-13T10:00:00.000Z"),
            Fixture.codexCall("function_call", id: "c1", name: "exec_command", at: "2026-10-13T10:00:01.000Z"),
            Fixture.codexOutput("function_call_output", id: "c1", at: "2026-10-13T10:00:02.000Z"),
            Fixture.codexCall(id: "c2", name: "exec", at: "2026-10-13T10:00:03.000Z"),
        ]))
        #expect(result.state == .midToolCall)
        #expect(result.pendingToolName == "exec")
    }

    @Test("Codex: a turn that completed on an error did not finish its work")
    func codexErroredTurn() {
        let result = state("codex", [
            Fixture.codexEvent("task_started", at: "2026-10-13T10:00:00.000Z"),
            Fixture.codexEvent("task_complete", at: "2026-10-13T10:00:03.000Z",
                               extra: ["error": ["message": "Selected model is at capacity."]]),
        ])
        #expect(result?.state == .midTurn)
    }

    @Test("Codex: a turn the user aborted is idle")
    func codexAbortedTurn() {
        let result = state("codex", [
            Fixture.codexEvent("task_started", at: "2026-10-13T10:00:00.000Z"),
            Fixture.codexCall(id: "c1", name: "exec", at: "2026-10-13T10:00:01.000Z"),
            Fixture.codexEvent("turn_aborted", at: "2026-10-13T10:00:02.000Z"),
        ])
        #expect(result?.state == .idle)
    }

    @Test("A transcript file is read and fingerprinted by its last entry and size")
    func fileFingerprint() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = (directory as NSString).appendingPathComponent("t.jsonl")
        try Fixture.write([
            Fixture.codexEvent("task_started", at: "2026-10-13T10:00:00.000Z"),
            Fixture.codexCall(id: "c1", name: "exec", at: "2026-10-13T10:00:01.000Z"),
        ], to: path)
        let first = try #require(reader.interruption(kind: "codex", transcriptPath: path))
        try Fixture.write([
            Fixture.codexEvent("task_started", at: "2026-10-13T10:00:00.000Z"),
            Fixture.codexCall(id: "c1", name: "exec", at: "2026-10-13T10:00:01.000Z"),
            Fixture.codexOutput(id: "c1", at: "2026-10-13T10:05:00.000Z"),
        ], to: path)
        let second = try #require(reader.interruption(kind: "codex", transcriptPath: path))
        #expect(first.state == .midToolCall)
        #expect(second.state == .midTurn)
        #expect(first.fingerprint != second.fingerprint)
    }
}

@Suite("The continue prompt asks the agent to verify before continuing")
struct AgentContinuePromptTests {
    private let interruptedAt = AgentInterruptionReader.parseTimestamp("2026-10-13T17:42:05.000Z")!

    @Test("Mid-tool-call prompt fixture")
    func midToolCallFixture() throws {
        let text = try #require(AgentContinuePrompt().text(
            for: AgentInterruption(state: .midToolCall, interruptedAt: interruptedAt, pendingToolName: "Bash", fingerprint: "f"),
            reason: .restored,
            timeZone: TimeZone(identifier: "UTC")!
        ))
        #expect(text == """
        Your session stopped at 2026-10-13 17:42:05 GMT (2026-10-13T17:42:05Z) and has been relaunched. \
        Your last tool call (Bash) has no recorded result, so it may or may not have run or finished. \
        Before doing anything else, check the real state of everything that was in progress: git status and git log, \
        the state of any branch or pull request through the API, running processes, and any files you were writing. \
        Then report what is done and what is not, and continue only the unfinished parts. \
        Never redo a step whose effect already exists.
        """)
    }

    @Test("Mid-turn quota prompt names the reason and never just says continue")
    func midTurnQuota() throws {
        let text = try #require(AgentContinuePrompt().text(
            for: AgentInterruption(state: .midTurn, interruptedAt: interruptedAt, pendingToolName: nil, fingerprint: "f"),
            reason: .quotaRecovered,
            timeZone: TimeZone(identifier: "UTC")!
        ))
        #expect(text.hasPrefix("Your session stopped at 2026-10-13 17:42:05 GMT (2026-10-13T17:42:05Z) when its account ran out of quota"))
        #expect(text.contains("Your last action may not have completed."))
        #expect(text.contains("Never redo a step whose effect already exists."))
        #expect(text.lowercased() != "continue")
    }

    @Test("An idle session gets no prompt")
    func idleGetsNothing() {
        #expect(AgentContinuePrompt().text(
            for: AgentInterruption(state: .idle, interruptedAt: interruptedAt, pendingToolName: nil, fingerprint: "f"),
            reason: .restored
        ) == nil)
    }
}

@Suite("Auto-continue is opt-in, never for idle sessions, and never twice")
struct AgentAutoContinuePolicyTests {
    private let busy = AgentInterruption(state: .midToolCall, interruptedAt: nil, pendingToolName: "Bash", fingerprint: "a")

    @Test("Off by default")
    func offByDefault() {
        var claims = 0
        let decision = AgentAutoContinuePolicy().decide(
            kind: "codex", sessionID: Fixture.codexSession, enabledSetting: false, sessionOverride: nil,
            interruption: busy, reason: .restored, claim: { _ in claims += 1; return true }
        )
        #expect(decision == .disabled)
        #expect(claims == 0)
    }

    @Test("A per-session override wins over the setting, both ways")
    func sessionOverrideWins() {
        let on = AgentAutoContinuePolicy().decide(
            kind: "codex", sessionID: Fixture.codexSession, enabledSetting: false, sessionOverride: true,
            interruption: busy, reason: .restored, claim: { _ in true }
        )
        let off = AgentAutoContinuePolicy().decide(
            kind: "codex", sessionID: Fixture.codexSession, enabledSetting: true, sessionOverride: false,
            interruption: busy, reason: .restored, claim: { _ in true }
        )
        if case .send = on {} else { Issue.record("override on did not send: \(on)") }
        #expect(off == .disabled)
    }

    @Test("An idle session is never claimed or continued")
    func idleNeverContinued() {
        var claims = 0
        let decision = AgentAutoContinuePolicy().decide(
            kind: "claude", sessionID: Fixture.claudeSession, enabledSetting: true, sessionOverride: nil,
            interruption: AgentInterruption(state: .idle, interruptedAt: nil, pendingToolName: nil, fingerprint: "i"),
            reason: .restored, claim: { _ in claims += 1; return true }
        )
        #expect(decision == .idle)
        #expect(claims == 0)
    }

    @Test("The ledger grants one claim per interruption across instances and threads")
    func ledgerExactlyOnce() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let wins = ClaimCounter()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if AgentAutoContinueLedger(directory: directory)
                .claim(kind: "codex", sessionID: Fixture.codexSession, interruption: busy) {
                wins.increment()
            }
        }
        #expect(wins.count == 1)
        let later = AgentInterruption(state: .midTurn, interruptedAt: nil, pendingToolName: nil, fingerprint: "b")
        #expect(AgentAutoContinueLedger(directory: directory)
            .claim(kind: "codex", sessionID: Fixture.codexSession, interruption: later))
    }

    @Test("The service continues a busy Codex session once, then reports it already sent")
    func serviceEndToEnd() throws {
        let home = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Fixture.write([
            ["type": "session_meta", "timestamp": "2026-10-13T09:59:59.000Z",
             "payload": ["id": Fixture.codexSession, "model_provider": "subrouter"]],
            Fixture.codexEvent("task_started", at: "2026-10-13T10:00:00.000Z"),
            Fixture.codexCall(id: "c1", name: "exec", at: "2026-10-13T10:00:01.000Z"),
        ], to: "\(home)/.codex/sessions/2026/10/13/rollout-2026-10-13T10-00-00-\(Fixture.codexSession).jsonl")
        let service = AgentAutoContinueService(
            ledger: AgentAutoContinueLedger(directory: "\(home)/ledger"), homeDirectory: home
        )
        let dryRun = service.decide(kind: "codex", sessionID: Fixture.codexSession, environment: [:],
                                    enabledSetting: true, sessionOverride: nil, reason: .restored, ledgerMode: .dryRun)
        let first = service.decide(kind: "codex", sessionID: Fixture.codexSession, environment: [:],
                                   enabledSetting: true, sessionOverride: nil, reason: .restored)
        let second = service.decide(kind: "codex", sessionID: Fixture.codexSession, environment: [:],
                                    enabledSetting: true, sessionOverride: nil, reason: .restored)
        if case .send(let prompt, let interruption) = dryRun {
            #expect(prompt.contains("(exec)"))
            #expect(interruption.state == .midToolCall)
        } else {
            Issue.record("dry run did not offer a prompt: \(dryRun)")
        }
        guard case .send(_, let claimed) = first else {
            Issue.record("first decision did not send: \(first)")
            return
        }
        #expect(second == .alreadySent)
        let record = try #require(service.ledger.claimRecord(kind: "codex", sessionID: Fixture.codexSession, interruption: claimed))
        #expect(record["state"] as? String == "midToolCall")
        #expect(record["last_entry_was_open_tool_call"] as? Bool == true)
        #expect(record["pending_tool"] as? String == "exec")
        #expect(record["interrupted_at"] as? String == "2026-10-13T10:00:01Z")
    }

    @Test("A failed launch's retry carries the claimed prompt exactly once")
    func retryCarriesClaimedPrompt() throws {
        let home = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Fixture.write([
            ["type": "session_meta", "timestamp": "2026-10-13T09:59:59.000Z",
             "payload": ["id": Fixture.codexSession, "model_provider": "subrouter"]],
            Fixture.codexEvent("task_started", at: "2026-10-13T10:00:00.000Z"),
            Fixture.codexCall(id: "c1", name: "exec", at: "2026-10-13T10:00:01.000Z"),
        ], to: "\(home)/.codex/sessions/2026/10/13/rollout-2026-10-13T10-00-00-\(Fixture.codexSession).jsonl")
        let service = AgentAutoContinueService(
            ledger: AgentAutoContinueLedger(directory: "\(home)/ledger"), homeDirectory: home
        )
        func decide(_ mode: AgentAutoContinueService.LedgerMode) -> AgentAutoContinuePolicy.Decision {
            service.decide(kind: "codex", sessionID: Fixture.codexSession, environment: [:],
                           enabledSetting: true, sessionOverride: nil, reason: .restored, ledgerMode: mode)
        }
        // A carry with no claim behind it is not a retry of a continued launch.
        #expect(decide(.carry) == .alreadySent)
        guard case .send(let firstPrompt, _) = decide(.claim) else {
            Issue.record("the first attempt did not claim")
            return
        }
        guard case .send(let carried, _) = decide(.carry) else {
            Issue.record("the retry did not carry the claimed prompt")
            return
        }
        #expect(carried == firstPrompt)
        // A fresh claim for the same interruption still never sends again.
        #expect(decide(.claim) == .alreadySent)
        let claims = try FileManager.default.contentsOfDirectory(atPath: "\(home)/ledger")
        #expect(claims.count == 1)
    }

    @Test("An unreadable transcript sends nothing and claims nothing")
    func unknownTranscriptSendsNothing() throws {
        let home = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let service = AgentAutoContinueService(
            ledger: AgentAutoContinueLedger(directory: "\(home)/ledger"), homeDirectory: home
        )
        let decision = service.decide(kind: "claude", sessionID: Fixture.claudeSession, environment: [:],
                                      enabledSetting: true, sessionOverride: nil, reason: .quotaRecovered)
        #expect(decision == .unknown)
        #expect(!FileManager.default.fileExists(atPath: "\(home)/ledger"))
    }

    @Test("The per-session override is read from the launch environment")
    func sessionOverrideFromEnvironment() {
        #expect(AgentAutoContinueService.sessionOverride(in: ["CMUX_AGENT_AUTO_CONTINUE": "1"]) == true)
        #expect(AgentAutoContinueService.sessionOverride(in: ["CMUX_AGENT_AUTO_CONTINUE": "0"]) == false)
        #expect(AgentAutoContinueService.sessionOverride(in: [:]) == nil)
        #expect(AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: ["CMUX_AGENT_AUTO_CONTINUE": "1"]
        )["CMUX_AGENT_AUTO_CONTINUE"] == "1")
    }
}

@Suite("A restore relaunches through the right route and verifies it")
struct AgentRestoreRouteTests {
    private let ambient = [
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
        "HOME": "/Users/me",
        "CMUX_CODEX_WRAPPER_SHIM": "/shim/codex",
        "CMUX_CLAUDE_WRAPPER_SHIM": "/shim/claude",
    ]
    private let prompt = "Your session stopped at T. Before doing anything else, check the real state."

    private func planner() -> AgentRestorePlanner {
        AgentRestorePlanner(
            isExecutableFile: { ["/opt/homebrew/bin/sr", "/shim/codex", "/shim/claude"].contains($0) },
            codexSessionModelProvider: { _, _ in nil }
        )
    }

    private func request(kind: String, arguments: [String], environment: [String: String],
                         mode: AgentRestoreRequestMode = .resumeAgent) -> AgentRestoreRequest {
        let session = kind == "codex" ? Fixture.codexSession : Fixture.claudeSession
        return AgentRestoreRequest(
            mode: mode, kind: kind, checkpointID: session, source: "agent-hook",
            workingDirectory: "/tmp/project", environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: kind == "codex" ? "codex" : nil, executablePath: arguments.first,
                arguments: arguments, workingDirectory: "/tmp/project", environment: environment,
                capturedAt: 1, source: "test"
            ),
            preparedArguments: nil, observedPermissionMode: nil
        )
    }

    private let routedCodexEnvironment = [
        "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
        "CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
    ]
    private let routedClaudeEnvironment = [
        "SUBROUTER_CLAUDE_RESUME_COMMAND": "sr claude proxy --resume",
        "CMUX_AGENT_LAUNCH_SUBROUTER_CLAUDE_RESUME_COMMAND": "sr claude proxy --resume",
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:31415/v1",
        "CLAUDE_CONFIG_DIR": "/Users/me/.subrouter/codex/claude-proxy/25bf8e1a2393f1108d37029b",
    ]

    @Test("Forced plain retry of a routed Codex record resumes codex directly")
    func codexForcedPlain() throws {
        let invocation = try #require(planner().invocation(
            for: request(kind: "codex", arguments: ["/bin/codex", "-c", "model_provider=subrouter"],
                         environment: routedCodexEnvironment),
            ambientEnvironment: ambient, route: .plain
        ))
        #expect(AgentRestoreRoute.taken(by: invocation) == .plain, "\(invocation.arguments)")
        #expect(invocation.arguments.allSatisfy { !$0.contains("subrouter") })
    }

    @Test("Forced Subrouter retry of a plain Codex record resumes through sr")
    func codexForcedSubrouter() throws {
        let invocation = try #require(planner().invocation(
            for: request(kind: "codex", arguments: ["/bin/codex"], environment: [:]),
            ambientEnvironment: ambient, route: .subrouter
        ))
        #expect(Array(invocation.arguments.prefix(4)) == ["sr", "codex", "resume", Fixture.codexSession])
    }

    @Test("Forced plain retry of a routed Claude record drops Subrouter's auth selection")
    func claudeForcedPlain() throws {
        let invocation = try #require(planner().invocation(
            for: request(kind: "claude", arguments: ["/bin/claude"], environment: routedClaudeEnvironment),
            ambientEnvironment: ambient, route: .plain
        ))
        #expect(AgentRestoreRoute.taken(by: invocation) == .plain, "\(invocation.arguments)")
        #expect(invocation.arguments.contains("--resume"))
        #expect(invocation.environment["ANTHROPIC_BASE_URL"] == nil)
        #expect(invocation.environment["CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test("Forced Subrouter retry of a plain Claude record resumes through sr claude proxy")
    func claudeForcedSubrouter() throws {
        let invocation = try #require(planner().invocation(
            for: request(kind: "claude", arguments: ["/bin/claude"], environment: [:]),
            ambientEnvironment: ambient, route: .subrouter
        ))
        #expect(Array(invocation.arguments.prefix(5)) == ["sr", "claude", "proxy", "--resume", Fixture.claudeSession])
    }

    @Test("The continue prompt is the last argument, for every route and agent", arguments: [
        ("codex", AgentRestoreRoute.automatic), ("codex", .subrouter), ("claude", .automatic), ("claude", .subrouter),
    ])
    func continuePromptAppended(kind: String, route: AgentRestoreRoute) throws {
        let invocation = try #require(planner().invocation(
            for: request(kind: kind, arguments: ["/bin/\(kind)"], environment: [:]),
            ambientEnvironment: ambient, route: route, continuePrompt: prompt
        ))
        #expect(invocation.arguments.last == prompt)
        #expect(invocation.arguments.filter { $0 == prompt }.count == 1)
    }

    @Test("A record captured from a continued relaunch never replays the prompt", arguments: ["codex", "claude"])
    func capturedPromptIsNotReplayed(kind: String) throws {
        let session = kind == "codex" ? Fixture.codexSession : Fixture.claudeSession
        let captured = kind == "codex"
            ? ["/bin/codex", "resume", session, "-c", "check_for_update_on_startup=false", prompt]
            : ["/bin/claude", "--resume", session, "--permission-mode", "auto", prompt]
        let invocation = try #require(planner().invocation(
            for: request(kind: kind, arguments: captured, environment: [:]),
            ambientEnvironment: ambient
        ))
        #expect(!invocation.arguments.contains(prompt), "\(invocation.arguments)")
    }

    @Test("A direct replay never carries a continue prompt")
    func directReplayHasNoPrompt() throws {
        let invocation = try #require(planner().invocation(
            for: request(kind: "codex", arguments: ["/bin/codex"], environment: [:], mode: .direct),
            ambientEnvironment: ambient, continuePrompt: prompt
        ))
        #expect(!invocation.arguments.contains(prompt))
    }

    @Test("Verification: alive past the grace period or session evidence is verified")
    func verified() {
        let verification = AgentRestoreLaunchVerification()
        #expect(verification.next(kind: "codex", sessionID: "s", processAlive: true,
                                  elapsed: AgentRestoreLaunchVerification.gracePeriod, sessionEvidence: false,
                                  attempt: 1, route: .subrouter) == .verified)
        #expect(verification.next(kind: "codex", sessionID: "s", processAlive: false, elapsed: 2,
                                  sessionEvidence: true, attempt: 1, route: .subrouter) == .verified)
        #expect(verification.next(kind: "codex", sessionID: "s", processAlive: true, elapsed: 2,
                                  sessionEvidence: false, attempt: 1, route: .subrouter) == .pending)
    }

    @Test("Verification: a fast exit retries once on the other route, then gives up with a fix")
    func retryThenGiveUp() {
        let verification = AgentRestoreLaunchVerification()
        #expect(verification.next(kind: "codex", sessionID: "s", processAlive: false, elapsed: 1,
                                  sessionEvidence: false, attempt: 1, route: .subrouter) == .retry(.plain))
        #expect(verification.next(kind: "claude", sessionID: "s", processAlive: false, elapsed: 1,
                                  sessionEvidence: false, attempt: 1, route: .plain) == .retry(.subrouter))
        guard case .giveUp(let message) = verification.next(
            kind: "codex", sessionID: "s", processAlive: false, elapsed: 1,
            sessionEvidence: false, attempt: 2, route: .plain
        ) else {
            Issue.record("second failure did not give up")
            return
        }
        #expect(message.contains("sr codex resume s"))
        #expect(message.contains("codex resume s"))
        #expect(!message.contains("not found"))
    }
}

private final class ClaimCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
