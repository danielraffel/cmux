import CMUXAgentLaunch
import Darwin
import Foundation

/// Restore verification, route fallback and the opt-in continue prompt.
///
/// A restored agent replaces the `cmux restore` process (exec), so its exit is
/// not observable from the restore itself. Right before the exec, the restore
/// starts a detached `cmux __restore-watch` that polls the same pid. If the
/// agent exits before ``AgentRestoreLaunchVerification/gracePeriod`` without
/// writing to its transcript, it never reached its prompt: the watcher types
/// one retry through the other route into the surface, and after a second
/// failure it prints what to run instead. An agent that stays alive is never
/// touched.
extension CMUXCLI {
    struct RestoreRouteOptions {
        var route: AgentRestoreRoute = .automatic
        var attempt = 1
        /// The first attempt already claimed this interruption's continue
        /// prompt; the retry carries it without claiming again.
        var carriesContinuePrompt = false
    }

    /// Removes this file's restore flags from `arguments`.
    func restoreRouteOptions(_ arguments: [String]) throws -> (RestoreRouteOptions, [String]) {
        var options = RestoreRouteOptions()
        var remaining: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--route":
                guard index + 1 < arguments.count,
                      let route = AgentRestoreRoute(rawValue: arguments[index + 1]) else {
                    throw CLIError(message: "restore: --route takes automatic, subrouter or plain")
                }
                options.route = route
                index += 2
            case "--attempt":
                guard index + 1 < arguments.count, let attempt = Int(arguments[index + 1]), attempt >= 1 else {
                    throw CLIError(message: "restore: --attempt takes a positive number")
                }
                options.attempt = attempt
                index += 2
            case "--continue-carry":
                options.carriesContinuePrompt = true
                index += 1
            default:
                remaining.append(argument)
                index += 1
            }
        }
        return (options, remaining)
    }

    /// The global "continue where it left off" setting, read from the app's
    /// defaults domain. Off unless the user turned it on.
    func agentAutoContinueSetting(environment: [String: String]) -> Bool {
        let configured = environment["CMUX_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = configured.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app"
        return UserDefaults(suiteName: domain)?.bool(forKey: AgentAutoContinueService.settingDefaultsKey) ?? false
    }

    /// The continue prompt for a restore, or `nil` when none applies. The
    /// first attempt claims the interruption; a carried retry does not.
    func restoreContinuePrompt(
        record: RestoreRecord,
        options: RestoreRouteOptions,
        processEnvironment: [String: String]
    ) -> String? {
        guard record.mode == AgentRestoreRequestMode.resumeAgent.rawValue,
              record.kind == "codex" || record.kind == "claude",
              let sessionID = record.checkpointID,
              options.attempt == 1 || options.carriesContinuePrompt else {
            return nil
        }
        var environment = record.launchCommand?.environment ?? [:]
        environment.merge(record.environment) { _, saved in saved }
        let service = AgentAutoContinueService(ledger: .standard(), homeDirectory: NSHomeDirectory())
        let decision = service.decide(
            kind: record.kind,
            sessionID: sessionID,
            environment: environment,
            enabledSetting: agentAutoContinueSetting(environment: processEnvironment),
            sessionOverride: AgentAutoContinueService.sessionOverride(in: environment),
            reason: .restored,
            ledgerMode: options.carriesContinuePrompt ? .carry : .claim
        )
        if case .send(let prompt, _) = decision { return prompt }
        return nil
    }

    // MARK: Watcher

    struct RestoreWatchPlan {
        var kind: String
        var sessionID: String
        var surfaceID: String
        var attempt: Int
        var route: AgentRestoreRoute
        var carriesContinuePrompt: Bool
        var transcriptFingerprint: String?
    }

    func restoreWatchPlan(
        record: RestoreRecord,
        invocation: AgentRestoreInvocation,
        options: RestoreRouteOptions,
        surfaceID: String,
        continuePrompt: String?
    ) -> RestoreWatchPlan? {
        guard record.mode == AgentRestoreRequestMode.resumeAgent.rawValue,
              record.kind == "codex" || record.kind == "claude",
              let sessionID = record.checkpointID else {
            return nil
        }
        return RestoreWatchPlan(
            kind: record.kind,
            sessionID: sessionID,
            surfaceID: surfaceID,
            attempt: options.attempt,
            route: AgentRestoreRoute.taken(by: invocation),
            carriesContinuePrompt: continuePrompt != nil,
            transcriptFingerprint: transcriptFingerprint(kind: record.kind, sessionID: sessionID, environment: invocation.environment)
        )
    }

    private func transcriptFingerprint(kind: String, sessionID: String, environment: [String: String]) -> String? {
        AgentTranscriptLocator()
            .transcriptPath(kind: kind, sessionID: sessionID, environment: environment, homeDirectory: NSHomeDirectory())
            .flatMap { AgentInterruptionReader().interruption(kind: kind, transcriptPath: $0)?.fingerprint }
    }

    /// Starts the detached watcher for this process, which is about to exec the agent.
    func startRestoreWatch(_ plan: RestoreWatchPlan, environment: [String: String]) {
        guard let executable = Bundle.main.executablePath ?? CommandLine.arguments.first else { return }
        var arguments = [
            executable, "__restore-watch",
            "--pid", String(getpid()),
            "--kind", plan.kind,
            "--session", plan.sessionID,
            "--surface", plan.surfaceID,
            "--attempt", String(plan.attempt),
            "--route", plan.route.rawValue,
            "--started", String(Date().timeIntervalSince1970),
        ]
        if plan.carriesContinuePrompt { arguments.append("--continue-carry") }
        if let fingerprint = plan.transcriptFingerprint { arguments += ["--fingerprint", fingerprint] }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        var pid: pid_t = 0
        _ = withCStringArray(arguments) { argv in
            withEnvironmentCStringArray(environment) { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            }
        }
    }

    /// `cmux __restore-watch`: waits for the restored agent, then verifies.
    func runRestoreWatchCommand(commandArgs: [String], client: SocketClient) throws {
        func value(_ name: String) -> String? {
            guard let index = commandArgs.firstIndex(of: name), index + 1 < commandArgs.count else { return nil }
            return commandArgs[index + 1]
        }
        guard let pidText = value("--pid"), let pid = pid_t(pidText),
              let kind = value("--kind"), let sessionID = value("--session"),
              let surfaceID = value("--surface"),
              let attempt = value("--attempt").flatMap(Int.init),
              let route = value("--route").flatMap(AgentRestoreRoute.init(rawValue:)),
              let started = value("--started").flatMap(TimeInterval.init) else {
            throw CLIError(message: "__restore-watch: missing arguments")
        }
        let verification = AgentRestoreLaunchVerification()
        let deadline = started + AgentRestoreLaunchVerification.gracePeriod
        while kill(pid, 0) == 0 || errno == EPERM {
            if Date().timeIntervalSince1970 >= deadline { return }
            usleep(250_000)
        }
        let fingerprint = transcriptFingerprint(kind: kind, sessionID: sessionID, environment: ProcessInfo.processInfo.environment)
        let next = verification.next(
            kind: kind,
            sessionID: sessionID,
            processAlive: false,
            elapsed: Date().timeIntervalSince1970 - started,
            sessionEvidence: fingerprint != nil && fingerprint != value("--fingerprint"),
            attempt: attempt,
            route: route
        )
        let text: String
        switch next {
        case .verified, .pending:
            return
        case .retry(let retryRoute):
            var command = " \(AgentRestoreLaunch.cliStartupExecutableToken) restore \(kind) \(sessionID) --route \(retryRoute.rawValue) --attempt \(attempt + 1)"
            if commandArgs.contains("--continue-carry") { command += " --continue-carry" }
            text = command + "\n"
        case .giveUp(let message):
            text = " /usr/bin/printf '%s\\n' '\(message.replacingOccurrences(of: "'", with: ""))'\n"
        }
        _ = try client.sendV2(method: "surface.send_text", params: ["surface_id": surfaceID, "text": text])
    }

    // MARK: Shared continue prompt

    /// `cmux agent-continue-prompt --kind <claude|codex> --session <id>
    /// [--reason restored|quota|provider] [--dry-run [--json] | --commit <token>]`
    ///
    /// Prints the one shared continue prompt for an interrupted session and
    /// claims the interruption, so Subrouter's resumer and cmux never send it
    /// twice. A sender that types the prompt itself asks with `--dry-run
    /// --json`, which claims nothing and returns the prompt with a claim
    /// token, then claims with `--commit <token>` only after the prompt was
    /// submitted, so a failed delivery never consumes the interruption.
    ///
    /// Exit status: 0 printed (or claimed), 3 idle (never continue), 4 already
    /// sent, 5 transcript not found or unreadable (send nothing).
    /// `--json` is a global CLI flag, so the dispatcher removes it from
    /// `commandArgs` and passes it as `jsonOutput`.
    func runAgentContinuePromptCommand(commandArgs: [String], jsonOutput: Bool) throws {
        func value(_ name: String) -> String? {
            guard let index = commandArgs.firstIndex(of: name), index + 1 < commandArgs.count else { return nil }
            return commandArgs[index + 1]
        }
        let usage = "usage: cmux agent-continue-prompt --kind <claude|codex> --session <id> [--reason restored|quota|provider] [--dry-run [--json] | --commit <token>]"
        guard let kind = value("--kind"), kind == "claude" || kind == "codex",
              let sessionID = value("--session") else {
            throw CLIError(message: usage)
        }
        guard let reason = AgentContinuePrompt.Reason(rawValue: value("--reason") ?? "restored") else {
            throw CLIError(message: "agent-continue-prompt: --reason takes restored, quota or provider")
        }
        let ledger = AgentAutoContinueLedger.standard()
        if commandArgs.contains("--commit") {
            guard let token = value("--commit"),
                  let interruption = AgentAutoContinueLedger.interruption(fromClaimToken: token) else {
                throw CLIError(message: usage)
            }
            exit(ledger.claim(kind: kind, sessionID: sessionID, interruption: interruption) ? 0 : 4)
        }
        let decision = AgentAutoContinueService(ledger: ledger, homeDirectory: NSHomeDirectory()).decide(
            kind: kind,
            sessionID: sessionID,
            environment: ProcessInfo.processInfo.environment,
            enabledSetting: true,
            sessionOverride: nil,
            reason: reason,
            ledgerMode: commandArgs.contains("--dry-run") ? .dryRun : .claim
        )
        switch decision {
        case .send(let prompt, let interruption):
            if jsonOutput || commandArgs.contains("--json") {
                let object: [String: String] = [
                    "prompt": prompt,
                    "claim_token": AgentAutoContinueLedger.claimToken(for: interruption),
                ]
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } else {
                print(prompt)
            }
        case .idle:
            exit(3)
        case .alreadySent:
            exit(4)
        case .unknown, .disabled:
            // No readable transcript: nothing is known about what was in
            // flight and nothing could be claimed, so send nothing.
            exit(5)
        }
    }
}
